/* Job hook, bk_wait_events and bk_wake. */
#include "boomkat.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int hooks;
static bk_runtime hooked_rt;

static void on_job(bk_runtime rt, void *opaque) {
    assert(opaque == &hooks && rt == hooked_rt);
    hooks++;
}

static void *waker(void *arg) {
    usleep(50 * 1000);
    bk_wake((bk_runtime)arg);
    return NULL;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "loop.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

int main(void) {
    bk_ctx ctx = bk_create();
    bk_runtime rt = bk_get_runtime(ctx);
    hooked_rt = rt;
    bk_set_job_hook(rt, on_job, &hooks);

    /* One hook per empty-to-non-empty transition. */
    eval(ctx, "globalThis.n = 0; Promise.resolve().then(() => n++); Promise.resolve().then(() => n++)");
    assert(hooks == 1);
    assert(bk_run_jobs(rt) == BK_OK);
    assert(bk_to_number(ctx, eval(ctx, "n")) == 2);
    /* A job that enqueues another while draining does not report again. */
    eval(ctx, "Promise.resolve().then(() => Promise.resolve().then(() => n++))");
    assert(hooks == 2);
    bk_run_jobs(rt);
    assert(hooks == 2 && bk_to_number(ctx, eval(ctx, "n")) == 3);
    bk_value resolve;
    bk_value p = bk_new_promise(ctx, &resolve, NULL);
    bk_promise_then(ctx, p, eval(ctx, "() => n++"), 0);
    assert(hooks == 2);
    bk_call(ctx, resolve, BK_UNDEFINED, NULL, 0);
    assert(hooks == 3);
    bk_run_jobs(rt);

    /* Poll and timeout. */
    assert(bk_wait_events(rt, 0) == 0);
    double t0 = now_ms();
    assert(bk_wait_events(rt, 30) == 0);
    assert(now_ms() - t0 >= 25);

    /* A wake before the wait is latched, and consumed once. */
    bk_wake(rt);
    assert(bk_wait_events(rt, 0) == 1);
    assert(bk_wait_events(rt, 0) == 0);

    /* A wake from another thread ends an indefinite wait. */
    pthread_t th;
    pthread_create(&th, NULL, waker, rt);
    t0 = now_ms();
    assert(bk_wait_events(rt, -1) == 1);
    assert(now_ms() - t0 < 5000);
    pthread_join(th, NULL);

    /* An Atomics.waitAsync deadline ends a wait too. */
    eval(ctx, "globalThis.ia = new Int32Array(new SharedArrayBuffer(4)); globalThis.res = '';"
              " Atomics.waitAsync(ia, 0, 0, 20).value.then(v => { res = v })");
    t0 = now_ms();
    assert(bk_wait_events(rt, 5000) == 1);
    assert(now_ms() - t0 < 4000);
    for (int i = 0; i < 10 && !bk_to_bool(ctx, eval(ctx, "res === 'timed-out'")); i++) {
        bk_run_jobs(rt);
        bk_wait_events(rt, 10);
    }
    assert(bk_to_bool(ctx, eval(ctx, "res === 'timed-out'")));

    bk_set_job_hook(rt, NULL, NULL);
    int seen = hooks;
    eval(ctx, "Promise.resolve().then(() => n++)");
    assert(hooks == seen);
    bk_destroy(ctx);
    puts("event_loop: PASS");
    return 0;
}
