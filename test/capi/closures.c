/* C functions with per-function data and finalizers. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct { int id; int calls; int finalized; } box;

static int finalizer_runs;
static int finalize_opaque_ok;

static void finalize_box(void *data, void *opaque) {
    box *b = data;
    b->finalized++;
    finalizer_runs++;
    if (opaque == (void *)&finalizer_runs) finalize_opaque_ok++;
}

static bk_value tick(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)argc; (void)argv;
    box *b = opaque;
    b->calls++;
    return bk_new_number(ctx, b->id);
}

static bk_value make(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)ctx;
    (void)this_value; (void)argc; (void)argv;
    box *b = opaque;
    b->calls++;
    return BK_UNDEFINED;
}

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "closures.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

#define MANY 2000

int main(void) {
    static box boxes[MANY];
    bk_ctx ctx = bk_create();

    /* Many closures over one callback, each with its own data, name and length. */
    for (int i = 0; i < MANY; i++) {
        boxes[i].id = i;
        char name[16];
        snprintf(name, sizeof name, "f%d", i);
        bk_value f = bk_new_c_function(ctx, tick, name, i % 5, 0, &boxes[i], finalize_box, &finalizer_runs);
        assert(f != 0);
        if (i < 10) {
            char key[8];
            snprintf(key, sizeof key, "f%d", i);
            bk_set_global_property(ctx, key, strlen(key), f);
        }
        bk_free_value(ctx, f);
    }
    /* Unreferenced closures are finalized when collected; live ones are not. */
    eval(ctx, "for (let i = 0; i < 200000; i++) ({ a: [i] })");
    assert(finalizer_runs > 0 && finalizer_runs <= MANY - 10 && finalize_opaque_ok == finalizer_runs);
    for (int i = 0; i < 10; i++) assert(boxes[i].finalized == 0);

    /* Every call route hands the callback this function's data. */
    assert(bk_to_bool(ctx, eval(ctx,
        "f3() === 3 && f3.call(null) === 3 && f3.apply(null, []) === 3 && Reflect.apply(f3, null, []) === 3"
        " && f3.bind(null)() === 3 && [0].map(f4)[0] === 4 && f5.name === 'f5' && f5.length === 0"
        " && f4.length === 4 && f2.name === 'f2'")));
    assert(boxes[3].calls == 5 && boxes[4].calls == 1);
    eval(ctx, "globalThis.seen = 0; Promise.resolve().then(f6).then(v => { seen = v })");
    assert(bk_run_jobs(bk_get_runtime(ctx)) == BK_OK);
    assert(bk_to_number(ctx, eval(ctx, "seen")) == 6);

    /* Constructors: shared slot per (callback, BK_CTOR), data per function. */
    box ca = { .id = 100 }, cb = { .id = 200 };
    bk_value A = bk_new_c_function(ctx, make, "A", 0, BK_CTOR, &ca, NULL, NULL);
    bk_value B = bk_new_c_function(ctx, make, "B", 0, 0, &cb, NULL, NULL);
    bk_set_global_property(ctx, "A", 1, A);
    bk_set_global_property(ctx, "B", 1, B);
    assert(bk_to_bool(ctx, eval(ctx, "new A() instanceof A && (() => { try { new B(); return false } catch (e) { return e instanceof TypeError } })()"
                                     " && (class extends A {}, true)")));
    assert(ca.calls == 1 && cb.calls == 0);
    /* Without a finalizer and data, nothing is attached. */
    bk_value plain = bk_new_c_function(ctx, make, "plain", 0, 0, NULL, NULL, NULL);
    assert(bk_to_bool(ctx, eval(ctx, "Object.getOwnPropertySymbols(f3).length === 0 && Reflect.ownKeys(f3).join() === 'length,name'")));
    bk_free_value(ctx, plain);

    /* A function list entry owns its data too. */
    box listed = { .id = 7 };
    bk_fn_def defs[] = {{"listed", tick, 0, 0u, &listed, finalize_box, NULL}, BK_FN_END};
    assert(bk_set_function_list(ctx, 0, defs) == BK_OK);
    assert(bk_to_number(ctx, eval(ctx, "listed()")) == 7);

    /* A failed creation finalizes at once. */
    box failed = { .id = -1 };
    assert(bk_new_c_function(ctx, NULL, "x", 0, 0, &failed, finalize_box, NULL) == 0);
    assert(failed.finalized == 1);

    /* Teardown finalizes the rest, including closures held in a cycle. */
    eval(ctx, "globalThis.cycle = { f: f7 }; cycle.self = cycle; f7.owner = cycle; delete globalThis.f7");
    bk_destroy(ctx);
    for (int i = 0; i < MANY; i++) assert(boxes[i].finalized == 1);
    assert(listed.finalized == 1);
    puts("closures: PASS");
    return 0;
}
