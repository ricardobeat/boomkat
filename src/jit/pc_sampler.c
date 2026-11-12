/*
 * pc_sampler.c — a sampling profiler for scripts/jit_profile.py (CLI
 * --sample-pcs): where the thread that started it was, every period.
 *
 * A sample is the pc, the link register (arm64) and the return addresses of a
 * few frames along the frame-pointer chain, kept within the thread's stack.
 * On macOS a sampling thread suspends the target and reads its registers, as
 * /usr/bin/sample does: a CPU-time timer signal there waits for the thread's
 * next kernel entry, which piles samples onto system calls. On Linux the
 * CPU-time timer's signal arrives on the tick; it may land on any thread,
 * which passes it on to the target.
 *
 * At the end each address is classified with dladdr: the engine's own image
 * (symbolized by the script), a library symbol, or no image, which is
 * generated code that the script finds in the --jit-dump-feedback code map of
 * the same process. Register state is platform-specific, so this is C.
 */
#if (defined(__APPLE__) || defined(__linux__)) && (defined(__aarch64__) || defined(__x86_64__))
#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#else
#include <sys/time.h>
#include <ucontext.h>
#endif

#define SAMPLE_DEPTH 8 /* pc, link register, return addresses */

typedef struct { uintptr_t at[SAMPLE_DEPTH]; } Sample;

static Sample *samples;
static volatile size_t sample_count;
static size_t sample_cap;
static uintptr_t stack_low, stack_high;

/* Record a sample of a thread stopped at `pc` with link register `lr` (0 if
 * none) and frame pointer `fp`. */
static void record(uintptr_t pc, uintptr_t lr, uintptr_t fp)
{
    size_t n = sample_count;
    if (n >= sample_cap) return;
    Sample *s = &samples[n];
    s->at[0] = pc;
    s->at[1] = lr;
    /* Each frame holds the caller's frame pointer and then the return
     * address; frames only move up the stack. */
    for (int k = 2; k < SAMPLE_DEPTH; k++) {
        if (fp < stack_low || fp + 2 * sizeof(uintptr_t) > stack_high || (fp & (sizeof(uintptr_t) - 1))) break;
        uintptr_t *frame = (uintptr_t *)fp;
        s->at[k] = frame[1];
        if (frame[0] <= fp) break;
        fp = frame[0];
    }
    sample_count = n + 1;
}

#if defined(__APPLE__)
static thread_act_t target_thread;
static pthread_t sampling_thread;
static volatile int sampling_stop;
static long sample_after_us, sample_period_us;

static void sleep_us(long us)
{
    struct timespec ts = { us / 1000000, (us % 1000000) * 1000 };
    while (nanosleep(&ts, &ts) != 0) {}
}

static void *sampling_main(void *arg)
{
    (void)arg;
    for (long waited = 0; waited < sample_after_us && !sampling_stop; waited += 10000) sleep_us(10000);
    while (!sampling_stop && sample_count < sample_cap) {
        if (thread_suspend(target_thread) == KERN_SUCCESS) {
#if defined(__aarch64__)
            arm_thread_state64_t st;
            mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(target_thread, ARM_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS)
                record((uintptr_t)arm_thread_state64_get_pc(st), (uintptr_t)arm_thread_state64_get_lr(st),
                       (uintptr_t)arm_thread_state64_get_fp(st));
#else
            x86_thread_state64_t st;
            mach_msg_type_number_t n = x86_THREAD_STATE64_COUNT;
            if (thread_get_state(target_thread, x86_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS)
                record((uintptr_t)st.__rip, 0, (uintptr_t)st.__rbp);
#endif
            thread_resume(target_thread);
        }
        sleep_us(sample_period_us);
    }
    return 0;
}

static int start_sampling(long after_us, long period_us)
{
    pthread_t self = pthread_self();
    stack_high = (uintptr_t)pthread_get_stackaddr_np(self);
    stack_low = stack_high - pthread_get_stacksize_np(self);
    target_thread = mach_thread_self();
    sample_after_us = after_us;
    sample_period_us = period_us;
    sampling_stop = 0;
    return pthread_create(&sampling_thread, 0, sampling_main, 0) == 0 ? 0 : -1;
}

static void stop_sampling(void)
{
    sampling_stop = 1;
    pthread_join(sampling_thread, 0);
    mach_port_deallocate(mach_task_self(), target_thread);
}
#else
static pthread_t target_thread;

static void on_profile_tick(int sig, siginfo_t *info, void *ctx)
{
    (void)info;
    if (!pthread_equal(pthread_self(), target_thread)) {
        pthread_kill(target_thread, sig);
        return;
    }
    ucontext_t *uc = (ucontext_t *)ctx;
#if defined(__aarch64__)
    record((uintptr_t)uc->uc_mcontext.pc, (uintptr_t)uc->uc_mcontext.regs[30], (uintptr_t)uc->uc_mcontext.regs[29]);
#else
    record((uintptr_t)uc->uc_mcontext.gregs[REG_RIP], 0, (uintptr_t)uc->uc_mcontext.gregs[REG_RBP]);
#endif
}

static int start_sampling(long after_us, long period_us)
{
    pthread_attr_t attr;
    void *addr = 0;
    size_t size = 0;
    if (pthread_getattr_np(pthread_self(), &attr) != 0) return -1;
    int rc = pthread_attr_getstack(&attr, &addr, &size);
    pthread_attr_destroy(&attr);
    if (rc != 0) return -1;
    stack_low = (uintptr_t)addr;
    stack_high = stack_low + size;
    target_thread = pthread_self();
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_profile_tick;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGPROF, &sa, 0) != 0) return -1;
    struct itimerval tv;
    if (after_us < 1) after_us = 1;
    tv.it_value.tv_sec = after_us / 1000000;
    tv.it_value.tv_usec = after_us % 1000000;
    tv.it_interval.tv_sec = period_us / 1000000;
    tv.it_interval.tv_usec = period_us % 1000000;
    return setitimer(ITIMER_PROF, &tv, 0);
}

static void stop_sampling(void)
{
    struct itimerval off;
    memset(&off, 0, sizeof off);
    setitimer(ITIMER_PROF, &off, 0);
    signal(SIGPROF, SIG_IGN);
}
#endif

/* Sample the calling thread every `period_us` after the first `after_us`
 * (CPU time on Linux, wall time on macOS), keeping at most `max_samples`.
 * Returns 0, or -1 if sampling could not start. */
int boomkat_sampler_start(long after_us, long period_us, size_t max_samples)
{
    samples = calloc(max_samples ? max_samples : 1, sizeof(Sample));
    if (!samples) return -1;
    sample_cap = max_samples;
    sample_count = 0;
    return start_sampling(after_us, period_us);
}

static void write_address(FILE *out, uintptr_t at, void *engine)
{
    Dl_info di;
    if (!dladdr((void *)at, &di) || !di.dli_fbase) {
        fprintf(out, " u:%lx", (unsigned long)at);
    } else if (di.dli_fbase == engine) {
        fprintf(out, " m:%lx", (unsigned long)at);
    } else {
        const char *lib = strrchr(di.dli_fname, '/');
        fprintf(out, " l:%s:%s", lib ? lib + 1 : di.dli_fname, di.dli_sname ? di.dli_sname : "?");
    }
}

/* Stop sampling and write the samples to `path`: a `base` line with the
 * engine image's load address and path, then an `s` line per sample,
 * innermost first: the pc, the link register (0 where there is none) and
 * return addresses, each `m:ADDR` (engine image), `l:LIBRARY:SYMBOL` or
 * `u:ADDR` (no image: generated code). */
int boomkat_sampler_finish(const char *path)
{
    stop_sampling();
    FILE *out = fopen(path, "w");
    if (!out) return -1;
    Dl_info self;
    void *engine = 0;
    if (dladdr((void *)boomkat_sampler_start, &self)) engine = self.dli_fbase;
    fprintf(out, "base %p %s\n", engine, engine ? self.dli_fname : "?");
    for (size_t i = 0; i < sample_count; i++) {
        fputc('s', out);
        for (int k = 0; k < SAMPLE_DEPTH; k++) {
            uintptr_t at = samples[i].at[k];
            if (at == 0) {
                if (k == 1) { fputs(" 0", out); continue; }
                break;
            }
            write_address(out, at, engine);
        }
        fputc('\n', out);
    }
    free(samples);
    samples = 0;
    return fclose(out);
}
#else
#include <stddef.h>
int boomkat_sampler_start(long after_us, long period_us, size_t max_samples)
{
    (void)after_us; (void)period_us; (void)max_samples;
    return -1;
}
int boomkat_sampler_finish(const char *path) { (void)path; return -1; }
#endif
