/* Promise creation, settlement, state, reactions and rejection tracking. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int fulfilled_with = -1, rejections;
static bk_value seen_value;

static bk_value on_ok(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)opaque;
    fulfilled_with = argc > 0 ? (int)bk_to_number(ctx, argv[0]) : -2;
    return bk_new_number(ctx, fulfilled_with + 1);
}

static void track(bk_ctx ctx, uint64_t id, bk_value promise, bk_value reason, int handled, void *opaque) {
    (void)ctx; (void)id; (void)promise; (void)reason; (void)opaque;
    if (!handled) rejections++;
}

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "promises.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

static bk_promise_state state(bk_ctx ctx, bk_value p) {
    bk_promise_state s;
    assert(bk_promise_state_get(ctx, p, &s) == BK_OK);
    return s;
}

int main(void) {
    bk_ctx ctx = bk_create();
    bk_runtime rt = bk_get_runtime(ctx);
    (void)seen_value;

    bk_value resolve, reject;
    bk_value p = bk_new_promise(ctx, &resolve, &reject);
    assert(state(ctx, p) == BK_PROMISE_PENDING && bk_promise_result(ctx, p) == BK_UNDEFINED);
    bk_value ok = bk_new_c_function(ctx, on_ok, "ok", 1, 0, NULL, NULL, NULL);
    bk_value chained = bk_promise_then(ctx, p, ok, 0);
    assert(chained && state(ctx, chained) == BK_PROMISE_PENDING);
    bk_value v = bk_new_number(ctx, 41);
    bk_call(ctx, resolve, BK_UNDEFINED, &v, 1);
    assert(state(ctx, p) == BK_PROMISE_FULFILLED && bk_to_number(ctx, bk_promise_result(ctx, p)) == 41);
    assert(fulfilled_with == -1);
    assert(bk_run_jobs(rt) == BK_OK);
    assert(fulfilled_with == 41 && bk_to_number(ctx, bk_promise_result(ctx, chained)) == 42);

    /* Resolving with a thenable adopts it. */
    bk_value p2 = bk_new_promise(ctx, &resolve, NULL);
    bk_value thenable = eval(ctx, "({ then(r) { r('adopted') } })");
    bk_call(ctx, resolve, BK_UNDEFINED, &thenable, 1);
    assert(state(ctx, p2) == BK_PROMISE_PENDING);
    bk_run_jobs(rt);
    char buf[16];
    assert(state(ctx, p2) == BK_PROMISE_FULFILLED);
    assert(bk_read_string(ctx, bk_promise_result(ctx, p2), buf, sizeof buf, NULL) == BK_OK && !strcmp(buf, "adopted"));

    /* Rejection tracking and bk_promise_mark_handled. */
    bk_set_promise_rejection_tracker(rt, track, NULL);
    bk_value p3 = bk_new_promise(ctx, NULL, &reject);
    bk_value why = bk_new_error(ctx, BK_ERROR, "no");
    bk_call(ctx, reject, BK_UNDEFINED, &why, 1);
    assert(state(ctx, p3) == BK_PROMISE_REJECTED && bk_strict_equals(ctx, bk_promise_result(ctx, p3), why));
    bk_run_jobs(rt);
    int before = rejections;
    assert(before >= 1);
    assert(bk_promise_mark_handled(ctx, p3) == BK_OK);
    bk_value p4 = bk_new_promise(ctx, NULL, &reject);
    assert(bk_promise_mark_handled(ctx, p4) == BK_OK);
    bk_call(ctx, reject, BK_UNDEFINED, &why, 1);
    bk_run_jobs(rt);
    assert(rejections == before);

    /* Promise.resolve keeps a promise and wraps anything else. */
    assert(bk_strict_equals(ctx, bk_promise_resolve(ctx, p), p));
    bk_value wrapped = bk_promise_resolve(ctx, bk_new_number(ctx, 3));
    assert(state(ctx, wrapped) == BK_PROMISE_FULFILLED && bk_to_number(ctx, bk_promise_result(ctx, wrapped)) == 3);
    bk_value from_js = eval(ctx, "Promise.reject(1).catch(() => 'caught')");
    bk_run_jobs(rt);
    assert(state(ctx, from_js) == BK_PROMISE_FULFILLED);

    /* Type checks. */
    bk_promise_state s;
    assert(bk_promise_state_get(ctx, bk_new_number(ctx, 1), &s) == BK_ERR_TYPE);
    assert(bk_promise_then(ctx, eval(ctx, "({})"), ok, 0) == 0 && bk_get_error_code(ctx) == BK_ERR_THROW);
    bk_free_value(ctx, bk_get_exception(ctx));

    bk_destroy(ctx);
    puts("promises: PASS");
    return 0;
}
