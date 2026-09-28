/* Phase A: the pthreads that ERTS uses, as green threads on JSPI. */
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

/* 1. A mutex: 4 threads, 1000 increments each, with a switch inside the lock. */
static pthread_mutex_t mx = PTHREAD_MUTEX_INITIALIZER;
static long counter;
static void *incr(void *arg)
{
    int i;
    (void)arg;
    for (i = 0; i < 1000; i++) {
        pthread_mutex_lock(&mx);
        long v = counter;
        if (i % 7 == 0)
            sched_yield(); /* the others wait for the lock */
        counter = v + 1;
        pthread_mutex_unlock(&mx);
    }
    return NULL;
}

/* 2. A condition variable: a producer and a consumer, a queue of 4. */
static pthread_mutex_t qm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t notempty = PTHREAD_COND_INITIALIZER, notfull = PTHREAD_COND_INITIALIZER;
static int queue[4], qlen, qhead;
static void *producer(void *arg)
{
    int i;
    (void)arg;
    for (i = 1; i <= 1000; i++) {
        pthread_mutex_lock(&qm);
        while (qlen == 4)
            pthread_cond_wait(&notfull, &qm);
        queue[(qhead + qlen++) % 4] = i;
        pthread_cond_signal(&notempty);
        pthread_mutex_unlock(&qm);
    }
    return NULL;
}
static void *consumer(void *arg)
{
    long sum = 0;
    int i;
    (void)arg;
    for (i = 1; i <= 1000; i++) {
        pthread_mutex_lock(&qm);
        while (qlen == 0)
            pthread_cond_wait(&notempty, &qm);
        sum += queue[qhead];
        qhead = (qhead + 1) % 4;
        qlen--;
        pthread_cond_signal(&notfull);
        pthread_mutex_unlock(&qm);
    }
    return (void *)sum;
}

/* 3. Thread data (keys) and the shadow stack: each thread keeps its own
 * values in a key and in a local array (in linear memory) across switches. */
static pthread_key_t key;
static void *keeper(void *arg)
{
    int id = (int)(long)arg, i, round;
    volatile int local[64]; /* address taken: in the shadow stack */
    for (i = 0; i < 64; i++)
        local[i] = id * 1000 + i;
    pthread_setspecific(key, (void *)(long)(id + 1));
    for (round = 0; round < 50; round++) {
        sched_yield();
        if ((long)pthread_getspecific(key) != id + 1)
            return (void *)1;
        for (i = 0; i < 64; i++)
            if (local[i] != id * 1000 + i)
                return (void *)2;
    }
    return (void *)0;
}

/* 3b. Nested frames in the shadow stack: recursion with an array in
 * linear memory at each level, and a switch on the way down and back. The
 * frames of each thread must stay intact while the others run. */
/* A new frame of 1 KB in the shadow stack, written: right after a switch,
 * it must land in the stack of the running thread, not in the live frames
 * of another thread. */
static void __attribute__((noinline)) scribble(int id)
{
    volatile int big[256];
    int i;
    for (i = 0; i < 256; i++)
        big[i] = -id;
}

static int __attribute__((noinline)) deep(int id, int depth)
{
    volatile int buf[32];
    int i, bad = 0;
    for (i = 0; i < 32; i++)
        buf[i] = id * 100000 + depth * 100 + i;
    sched_yield();
    scribble(id);
    if (depth > 0)
        bad |= deep(id, depth - 1);
    sched_yield();
    scribble(id);
    for (i = 0; i < 32; i++)
        if (buf[i] != id * 100000 + depth * 100 + i)
            bad = 1;
    return bad;
}
static void *nested(void *arg)
{
    int id = (int)(long)arg, round, bad = 0;
    for (round = 0; round < 20; round++)
        bad |= deep(id, 8);
    return (void *)(long)bad;
}

/* 4. A timed wait that times out, and one that is signaled in time. */
static pthread_cond_t tc = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t tm = PTHREAD_MUTEX_INITIALIZER;
static void *signaler(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&tm);
    pthread_cond_signal(&tc);
    pthread_mutex_unlock(&tm);
    return NULL;
}
static int timedwait_ms(int ms)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += (long)ms * 1000000;
    ts.tv_sec += ts.tv_nsec / 1000000000;
    ts.tv_nsec %= 1000000000;
    return pthread_cond_timedwait(&tc, &tm, &ts);
}

/* 5. The cost of a switch: two threads, ping-pong on a condition variable. */
static pthread_mutex_t pm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pc = PTHREAD_COND_INITIALIZER;
static int turn, rounds = 20000;
static void *pong(void *arg)
{
    int i, me = (int)(long)arg;
    for (i = 0; i < rounds; i++) {
        pthread_mutex_lock(&pm);
        while (turn != me)
            pthread_cond_wait(&pc, &pm);
        turn = !me;
        pthread_cond_signal(&pc);
        pthread_mutex_unlock(&pm);
    }
    return NULL;
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(void)
{
    pthread_t t[8];
    void *ret;
    int i, r;
    double t0, t1;

    for (i = 0; i < 4; i++)
        pthread_create(&t[i], NULL, incr, NULL);
    for (i = 0; i < 4; i++)
        pthread_join(t[i], NULL);
    CHECK(counter == 4000, "mutex: counter %ld, not 4000", counter);
    printf("1. mutex: counter %ld\n", counter);

    pthread_create(&t[0], NULL, producer, NULL);
    pthread_create(&t[1], NULL, consumer, NULL);
    pthread_join(t[0], NULL);
    pthread_join(t[1], &ret);
    CHECK((long)ret == 500500, "cond: sum %ld, not 500500", (long)ret);
    printf("2. condition variable: sum %ld\n", (long)ret);

    pthread_key_create(&key, NULL);
    pthread_setspecific(key, (void *)99L);
    for (i = 0; i < 8; i++)
        pthread_create(&t[i], NULL, keeper, (void *)(long)i);
    for (i = 0; i < 8; i++) {
        pthread_join(t[i], &ret);
        CHECK(ret == 0, "keys/stack: thread %d gave %ld", i, (long)ret);
    }
    CHECK((long)pthread_getspecific(key) == 99, "keys: main lost its value");
    printf("3. keys and shadow stacks: 8 threads x 50 switches\n");

    for (i = 0; i < 4; i++)
        pthread_create(&t[i], NULL, nested, (void *)(long)(i + 1));
    for (i = 0; i < 4; i++) {
        pthread_join(t[i], &ret);
        CHECK(ret == 0, "nested frames: thread %d lost its frames", i);
    }
    printf("3b. nested frames: 4 threads, depth 8, 20 rounds\n");

    pthread_mutex_lock(&tm);
    t0 = now_ms();
    r = timedwait_ms(100);
    t1 = now_ms();
    CHECK(r == ETIMEDOUT && t1 - t0 >= 90, "timedwait: %d after %.0f ms", r, t1 - t0);
    printf("4. timed wait: %s after %.0f ms", r == ETIMEDOUT ? "ETIMEDOUT" : "signaled", t1 - t0);
    pthread_create(&t[0], NULL, signaler, NULL);
    r = timedwait_ms(5000);
    pthread_mutex_unlock(&tm);
    pthread_join(t[0], NULL);
    CHECK(r == 0, "timedwait: not signaled (%d)", r);
    printf("; with a signal: %s\n", r == 0 ? "signaled" : "ETIMEDOUT");

    t0 = now_ms();
    pthread_create(&t[0], NULL, pong, (void *)0L);
    pthread_create(&t[1], NULL, pong, (void *)1L);
    pthread_join(t[0], NULL);
    pthread_join(t[1], NULL);
    t1 = now_ms();
    printf("5. switches: %d in %.0f ms (%.2f us each)\n", 2 * rounds, t1 - t0, (t1 - t0) * 1000 / (2 * rounds));

    printf("%s\n", failures ? "FAILED" : "all passed");
    return failures != 0;
}
