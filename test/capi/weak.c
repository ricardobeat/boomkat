/* Weak handles: cleared after collection and after a symbol's last reference
 * goes, kept while the target lives, shared per target, and validated. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "weak.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

static void churn(bk_ctx ctx) {
    eval(ctx, "{ let keep = []; for (let i = 0; i < 200000; i++) { keep.push({ i }); if (keep.length > 64) keep = [] } }");
}

int main(void) {
    bk_ctx ctx = bk_create();

    /* A target kept alive by JS stays readable. */
    bk_value kept = eval(ctx, "globalThis.kept = { name: 'kept' }");
    bk_weak wk = bk_new_weak(ctx, kept);
    assert(wk != 0);
    bk_free_value(ctx, kept);

    /* A cycle reachable only through the weak handle is collected. */
    bk_value doomed = eval(ctx, "{ const a = { tag: 'doomed' }; a.self = a; a }");
    bk_weak wd = bk_new_weak(ctx, doomed);
    bk_weak wd2 = bk_new_weak(ctx, doomed);
    assert(wd2 == wd);
    bk_value again = bk_weak_get(ctx, wd);
    assert(bk_strict_equals(ctx, again, doomed));
    bk_free_value(ctx, again);
    bk_free_value(ctx, doomed);
    int rounds = 0;
    for (; rounds < 50; rounds++) {
        bk_value v = bk_weak_get(ctx, wd);
        if (v == BK_UNDEFINED) break;
        bk_free_value(ctx, v);
        churn(ctx);
    }
    assert(rounds < 50);
    bk_value live = bk_weak_get(ctx, wk);
    bk_value name = bk_get_property(ctx, live, "name", 4);
    char buf[8];
    assert(bk_read_string(ctx, name, buf, sizeof buf, NULL) == BK_OK && !strcmp(buf, "kept"));
    bk_free_value(ctx, name);
    bk_free_value(ctx, live);
    bk_free_weak(ctx, wd);
    assert(bk_weak_get(ctx, wd2) == BK_UNDEFINED);
    bk_free_weak(ctx, wd2);
    assert(bk_weak_get(ctx, wd) == 0 && bk_get_error_code(ctx) == BK_ERR_INVALID);

    /* A symbol dies with its last reference. */
    bk_value sym = bk_new_symbol(ctx, "s", 1);
    bk_weak ws = bk_new_weak(ctx, sym);
    bk_value same = bk_weak_get(ctx, ws);
    assert(bk_strict_equals(ctx, same, sym));
    bk_free_value(ctx, same);
    bk_free_value(ctx, sym);
    for (rounds = 0; rounds < 50 && bk_weak_get(ctx, ws) != BK_UNDEFINED; rounds++) churn(ctx);
    assert(rounds < 50);
    bk_free_weak(ctx, ws);

    /* A result the host frees is collectable at once: neither an eval's
     * completion value nor a call's return value stays parked until the next
     * run. */
    bk_runtime rt = bk_get_runtime(ctx);
    bk_value done = eval(ctx, "({ completion: true })");
    bk_weak wc = bk_new_weak(ctx, done);
    bk_free_value(ctx, done);
    bk_gc(rt, BK_GC_FULL);
    assert(bk_weak_get(ctx, wc) == BK_UNDEFINED);
    bk_free_weak(ctx, wc);
    bk_value once = eval(ctx, "(() => { let t = { returned: true }; return () => { const r = t; t = null; return r } })()");
    bk_value ret = bk_call(ctx, once, BK_UNDEFINED, NULL, 0);
    bk_weak wr = bk_new_weak(ctx, ret);
    bk_free_value(ctx, ret);
    bk_gc(rt, BK_GC_FULL);
    assert(bk_weak_get(ctx, wr) == BK_UNDEFINED);
    bk_free_weak(ctx, wr);
    bk_free_value(ctx, once);

    /* Primitives and registered symbols are refused. */
    assert(bk_new_weak(ctx, bk_new_number(ctx, 1)) == 0 && bk_get_error_code(ctx) == BK_ERR_TYPE);
    assert(bk_new_weak(ctx, bk_symbol_for(ctx, "k", 1)) == 0 && bk_get_error_code(ctx) == BK_ERR_TYPE);

    /* Entries are reused and stale handles stay invalid. */
    bk_value o = eval(ctx, "globalThis.o2 = {}");
    bk_weak w2 = bk_new_weak(ctx, o);
    assert(w2 != wd && bk_weak_get(ctx, wd) == 0);
    bk_free_value(ctx, o);

    /* Teardown with live weak handles. */
    bk_destroy(ctx);
    puts("weak: PASS");
    return 0;
}
