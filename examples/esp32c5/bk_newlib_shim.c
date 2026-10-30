/* ESP-IDF's newlib differs from the glibc ABI that C3's linux-riscv32 target
 * assumes: time_t is 64-bit there but 32-bit (CLong) in C3, clock ids are
 * numbered differently, struct tm has no tm_gmtoff, and errno and the std
 * streams are reached through the reentrancy struct rather than globals.
 * `just build-esp32` renames the engine's references to these symbols to
 * bk_* so only boomkat goes through this translation. */
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef int32_t c3_time_t;

struct c3_timespec {
    c3_time_t sec;
    long nsec;
};

struct c3_tm {
    int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst;
    long tm_gmtoff;
    char *tm_zone;
};

/* C3's priority initializers, moved out of .init_array by the build. They set
 * thread-locals, which ESP-IDF does not provide until a task runs, and they
 * mark the calling task as the one allowed an implicit temp allocator. */
typedef void (*bk_init_fn)(void);
extern bk_init_fn bk_init_array_start[], bk_init_array_end[];

void bk_esp32_init(void)
{
    for (bk_init_fn *f = bk_init_array_start; f < bk_init_array_end; f++) (*f)();
}

FILE *bk_stdout;
FILE *bk_stderr;

__attribute__((constructor)) static void bk_shim_init(void)
{
    bk_stdout = stdout;
    bk_stderr = stderr;
}

int *bk_errno_location(void)
{
    return &errno;
}

static clockid_t bk_clock_id(int glibc_id)
{
    switch (glibc_id) {
    case 1: return CLOCK_MONOTONIC;
    default: return CLOCK_REALTIME;
    }
}

int bk_clock_gettime(int clock, struct c3_timespec *out)
{
    struct timespec ts;
    int rc = clock_gettime(bk_clock_id(clock), &ts);
    if (rc == 0) {
        out->sec = (c3_time_t)ts.tv_sec;
        out->nsec = ts.tv_nsec;
    }
    return rc;
}

/* ESP-IDF has no nanosleep; usleep sleeps the calling task. */
int bk_nanosleep(const struct c3_timespec *req, struct c3_timespec *rem)
{
    usleep((useconds_t)req->sec * 1000000u + (useconds_t)(req->nsec / 1000));
    if (rem) {
        rem->sec = 0;
        rem->nsec = 0;
    }
    return 0;
}

int bk_pthread_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                              const struct c3_timespec *abstime)
{
    struct timespec ts = { abstime->sec, abstime->nsec };
    return pthread_cond_timedwait(cond, mutex, &ts);
}

/* glibc's pthread_once_t is a zero-initialized int; newlib's is a struct that
 * must start as PTHREAD_ONCE_INIT. 0 = not run, 1 = running, 2 = done. */
int bk_pthread_once(int *once, void (*init)(void))
{
    int state = __atomic_load_n(once, __ATOMIC_ACQUIRE);
    if (state == 2) return 0;
    state = 0;
    if (__atomic_compare_exchange_n(once, &state, 1, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        init();
        __atomic_store_n(once, 2, __ATOMIC_RELEASE);
        return 0;
    }
    while (__atomic_load_n(once, __ATOMIC_ACQUIRE) != 2) sched_yield();
    return 0;
}

static long days_from_civil(long y, int m, int d)
{
    y -= m <= 2;
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;
    long doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

static struct c3_tm *bk_copy_tm(const struct tm *tm, long gmtoff, struct c3_tm *out)
{
    out->tm_sec = tm->tm_sec;
    out->tm_min = tm->tm_min;
    out->tm_hour = tm->tm_hour;
    out->tm_mday = tm->tm_mday;
    out->tm_mon = tm->tm_mon;
    out->tm_year = tm->tm_year;
    out->tm_wday = tm->tm_wday;
    out->tm_yday = tm->tm_yday;
    out->tm_isdst = tm->tm_isdst;
    out->tm_gmtoff = gmtoff;
    out->tm_zone = NULL;
    return out;
}

struct c3_tm *bk_gmtime_r(const c3_time_t *timer, struct c3_tm *out)
{
    time_t t = *timer;
    struct tm tm;
    if (!gmtime_r(&t, &tm)) return NULL;
    return bk_copy_tm(&tm, 0, out);
}

struct c3_tm *bk_localtime_r(const c3_time_t *timer, struct c3_tm *out)
{
    time_t t = *timer;
    struct tm tm;
    if (!localtime_r(&t, &tm)) return NULL;
    long local = days_from_civil(tm.tm_year + 1900L, tm.tm_mon + 1, tm.tm_mday) * 86400L
               + tm.tm_hour * 3600L + tm.tm_min * 60L + tm.tm_sec;
    return bk_copy_tm(&tm, local - (long)t, out);
}
