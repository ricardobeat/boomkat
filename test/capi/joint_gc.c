/* Joint collection with a host collector: host objects and their wrappers
 * point at each other, and a cycle through both heaps is collected only when
 * the host marks jointly. The host heap here is a fixed array with mark bits,
 * standing in for an embedder's tracing collector such as a browser's DOM heap. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

enum { HOST_CAPACITY = 64 };

/* A host object: alive or free, with a mark bit, a slot holding a JS value
 * (such as an event listener) and the wrapper that exposes it to JS. */
typedef struct {
    int alive;
    int marked;
    int rooted;
    bk_slot value;
    int wrapped;   /* a wrapper's payload points here */
} host_object;

static host_object host[HOST_CAPACITY];
static bk_runtime rt;
static bk_ctx ctx;
static bk_class Wrapper;
static bk_tracer *joint_tracer;
static int wrappers_freed;
static int joint_active;

static void host_mark(host_object *object);

static void trace_wrapper(void *payload, bk_tracer *tracer, void *opaque) {
    (void)tracer; (void)opaque;
    /* Wrapper -> host object: only meaningful to the host's own marking. */
    if (joint_active && payload) host_mark(payload);
}

static void free_wrapper(void *payload, void *opaque) {
    (void)opaque;
    ((host_object *)payload)->wrapped = 0;
    wrappers_freed++;
}

/* Host object -> JS value: while marking jointly the host shades the slot and
 * lets the engine mark from it, which reaches wrappers, which mark more host
 * objects. Outside joint cycles the root tracer reports every slot instead. */
static void host_mark(host_object *object) {
    if (!object->alive || object->marked) return;
    object->marked = 1;
    if (joint_active) {
        bk_trace_slot(joint_tracer, &object->value);
        bk_gc_joint_drain(rt);
    }
}

static void trace_roots(bk_tracer *tracer, void *opaque) {
    (void)opaque;
    if (bk_gc_in_joint_cycle(rt)) return;
    for (int i = 0; i < HOST_CAPACITY; i++)
        if (host[i].alive) bk_trace_slot(tracer, &host[i].value);
}

/* The host collector. With joint marking, wrappers the engine reaches from its
 * own roots mark their host objects while bk_gc_joint_begin runs; host roots
 * then mark the rest, each slot draining the engine's marking in turn. */
static int host_collect(void) {
    for (int i = 0; i < HOST_CAPACITY; i++) host[i].marked = 0;
    joint_active = 1;
    bk_status status = bk_gc_joint_begin(rt, &joint_tracer);
    assert(status == BK_OK && joint_tracer != NULL);
    assert(bk_gc_in_joint_cycle(rt));
    for (int i = 0; i < HOST_CAPACITY; i++)
        if (host[i].rooted) host_mark(&host[i]);
    bk_gc_joint_end(rt);
    joint_active = 0;
    joint_tracer = NULL;
    assert(!bk_gc_in_joint_cycle(rt));
    int freed = 0;
    for (int i = 0; i < HOST_CAPACITY; i++) {
        if (!host[i].alive || host[i].marked) continue;
        /* A dead host object's wrapper died in the same joint cycle. */
        assert(!host[i].wrapped);
        bk_slot_clear(ctx, &host[i].value);
        host[i].alive = 0;
        freed++;
    }
    return freed;
}

static int live_host_objects(void) {
    int n = 0;
    for (int i = 0; i < HOST_CAPACITY; i++) n += host[i].alive;
    return n;
}

/* make(): a new host object and its wrapper. */
static bk_value make(bk_ctx c, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)argc; (void)argv; (void)opaque;
    for (int i = 0; i < HOST_CAPACITY; i++) {
        if (host[i].alive) continue;
        memset(&host[i], 0, sizeof host[i]);
        host[i].alive = 1;
        host[i].wrapped = 1;
        bk_slot_init(&host[i].value);
        return bk_new_instance(c, Wrapper, &host[i], 0);
    }
    return bk_throw_error(c, BK_ERROR_RANGE, "host heap full");
}

/* hold(wrapper, value): the host object keeps `value`. */
static bk_value hold(bk_ctx c, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)opaque;
    host_object *object = argc > 1 ? bk_get_instance_payload(c, argv[0], Wrapper) : NULL;
    if (!object) return bk_throw_error(c, BK_ERROR_TYPE, "not a wrapper");
    if (bk_slot_set(c, &object->value, argv[1]) != BK_OK) return BK_EXCEPTION;
    return BK_UNDEFINED;
}

/* root(wrapper): the host keeps the object alive on its own, as a document does its nodes. */
static bk_value root(bk_ctx c, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)opaque;
    host_object *object = argc > 0 ? bk_get_instance_payload(c, argv[0], Wrapper) : NULL;
    if (!object) return bk_throw_error(c, BK_ERROR_TYPE, "not a wrapper");
    object->rooted = 1;
    return BK_UNDEFINED;
}

/* collect(): a joint collection from inside a callback; returns how many host objects it freed. */
static bk_value collect(bk_ctx c, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)argc; (void)argv; (void)opaque;
    return bk_new_number(c, host_collect());
}

static void run(const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "joint_gc.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    bk_free_value(ctx, r);
}

int main(void) {
    rt = bk_new_runtime(NULL);
    ctx = bk_new_context(rt, NULL);
    bk_set_root_tracer(rt, trace_roots, NULL);
    bk_class_def def = { "Wrapper", 0, free_wrapper, trace_wrapper, NULL, 0, 0, NULL, NULL };
    Wrapper = bk_define_class(ctx, &def, NULL, NULL);
    assert(Wrapper);
    bk_register_fn(ctx, 0, "make", make, 0, 0, NULL);
    bk_register_fn(ctx, 0, "hold", hold, 2, 0, NULL);
    bk_register_fn(ctx, 0, "root", root, 1, 0, NULL);
    assert(!bk_gc_in_joint_cycle(rt));

    /* Ten host objects each hold a closure over their own wrapper: a cycle
     * through both heaps. A collection of the engine alone keeps them all, since
     * every slot is a root then. */
    run("for (let i = 0; i < 10; i++) { const w = make(); hold(w, () => w); }");
    bk_gc(rt, BK_GC_FULL);
    assert(live_host_objects() == 10 && wrappers_freed == 0);

    /* A joint collection frees both sides of every cycle. */
    assert(host_collect() == 10);
    assert(wrappers_freed == 10 && live_host_objects() == 0);

    /* Reachable from the host's roots: the object, its value and, through the
     * value, its wrapper survive, and so does an object only JS reaches. */
    run("globalThis.kept = make(); root(kept); hold(kept, { wrapper: kept, tag: 'rooted' });"
        "globalThis.fromJS = make(); hold(fromJS, [1, 2, 3]);"
        "(function () { const a = make(); const b = make(); hold(a, b); hold(b, a); root(a); })();"
        "(function () { const c = make(); const d = make(); hold(c, d); hold(d, c); })();");
    assert(live_host_objects() == 6);
    assert(host_collect() == 2);
    assert(live_host_objects() == 4 && wrappers_freed == 12);
    run("if (globalThis.kept === undefined) throw new Error('lost kept');");

    /* The kept values are intact after the joint cycle. */
    int checked = 0;
    for (int i = 0; i < HOST_CAPACITY; i++) {
        if (!host[i].alive) continue;
        bk_value v = bk_slot_get(ctx, &host[i].value);
        assert(bk_get_type(ctx, v) == BK_TYPE_OBJECT || bk_get_type(ctx, v) == BK_TYPE_FUNCTION);
        bk_free_value(ctx, v);
        checked++;
    }
    assert(checked == 4);

    /* Dropping the JS root leaves the host-rooted pair and `kept`. */
    run("delete globalThis.fromJS;");
    assert(host_collect() == 1 && live_host_objects() == 3);

    /* From inside a native call, a joint cycle keeps what the running script
     * holds: `x` lives in a JS frame, so its host object survives. */
    bk_register_fn(ctx, 0, "collect", collect, 0, 0, NULL);
    run("(function () { const x = make(); hold(x, () => x); collect(); hold(x, 'still here'); })();");
    assert(live_host_objects() == 4);

    /* Back at the top level everything unrooted goes. */
    run("delete globalThis.kept;");
    for (int i = 0; i < HOST_CAPACITY; i++) host[i].rooted = 0;
    assert(host_collect() == 4 && live_host_objects() == 0);

    /* A joint cycle cannot nest. */
    assert(bk_gc_joint_begin(rt, &joint_tracer) == BK_OK);
    bk_tracer *nested = NULL;
    assert(bk_gc_joint_begin(rt, &nested) != BK_OK && nested == NULL);
    bk_gc_joint_end(rt);
    joint_tracer = NULL;

    for (int i = 0; i < HOST_CAPACITY; i++)
        if (host[i].alive) bk_slot_clear(ctx, &host[i].value);
    bk_free_context(ctx);
    bk_free_runtime(rt);
    printf("joint_gc: PASS (%d wrappers freed)\n", wrappers_freed);
    return 0;
}
