/* Traced slots: payload references and host roots survive collection while
 * traced, and cycles through payloads are collected. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { bk_slot held; int *freed; } node;

static bk_class Node;
static int nodes_freed;
static bk_slot root_slots[4];
static int root_traces;

static void free_node(void *payload, void *opaque) {
    (void)opaque;
    node *n = payload;
    (*n->freed)++;
    free(n);   /* a finalizer drops its slots without calling the engine */
}

static void trace_node(void *payload, bk_tracer *tracer, void *opaque) {
    (void)opaque;
    bk_trace_slot(tracer, &((node *)payload)->held);
}

static void trace_roots(bk_tracer *tracer, void *opaque) {
    assert(opaque == root_slots);
    root_traces++;
    for (int i = 0; i < 4; i++) bk_trace_slot(tracer, &root_slots[i]);
}

/* hold(obj): a Node whose payload holds obj. */
static bk_value hold(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)opaque;
    node *n = malloc(sizeof *n);
    n->freed = &nodes_freed;
    bk_slot_init(&n->held);
    if (argc > 0 && bk_slot_set(ctx, &n->held, argv[0]) != BK_OK) return BK_EXCEPTION;
    return bk_new_instance(ctx, Node, n, 0);
}

static bk_value held(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)argc; (void)argv; (void)opaque;
    node *n = bk_get_instance_payload(ctx, this_value, Node);
    if (!n) return bk_throw_error(ctx, BK_ERROR_TYPE, "not a Node");
    return bk_slot_get(ctx, &n->held);
}

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "tracing.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

static void churn(bk_ctx ctx) {
    eval(ctx, "for (let i = 0; i < 300000; i++) ({ a: [i], s: 'x' + i })");
}

int main(void) {
    bk_ctx ctx = bk_create();
    bk_value proto;
    bk_class_def def = { "Node", 0, free_node, trace_node, NULL, 0, 0, NULL };
    Node = bk_define_class(ctx, &def, NULL, &proto);
    assert(Node);
    bk_set_property(ctx, proto, "held", 4, bk_new_c_function(ctx, held, "held", 0, 0, NULL, NULL, NULL));
    bk_set_global_property(ctx, "hold", 4, bk_new_c_function(ctx, hold, "hold", 1, 0, NULL, NULL, NULL));

    /* A payload is the only path to its object; tracing keeps it alive. */
    eval(ctx, "globalThis.keep = hold({ tag: 'payload-only', list: [1, 2, 3] })");
    churn(ctx);
    assert(bk_to_bool(ctx, eval(ctx, "keep.held().tag === 'payload-only' && keep.held().list.join() === '1,2,3'")));

    /* Cycles through payloads are collected. */
    eval(ctx, "for (let i = 0; i < 2000; i++) { const o = { i }; o.node = hold(o) }");
    churn(ctx);
    assert(nodes_freed > 0);
    int before = nodes_freed;

    /* Host roots: a value reachable only from a root slot survives. */
    for (int i = 0; i < 4; i++) bk_slot_init(&root_slots[i]);
    bk_set_root_tracer(bk_get_runtime(ctx), trace_roots, root_slots);
    bk_value obj = eval(ctx, "({ rooted: 'yes' })");
    assert(bk_slot_set(ctx, &root_slots[1], obj) == BK_OK);
    bk_free_value(ctx, obj);
    eval(ctx, "globalThis.slotGarbage = null");
    churn(ctx);
    assert(root_traces > 0);
    bk_value back = bk_slot_get(ctx, &root_slots[1]);
    bk_value tag = bk_get_property(ctx, back, "rooted", 6);
    char buf[8];
    assert(bk_read_string(ctx, tag, buf, sizeof buf, NULL) == BK_OK && strcmp(buf, "yes") == 0);
    bk_free_value(ctx, back);
    bk_free_value(ctx, tag);
    /* Primitives and immediates round-trip. */
    assert(bk_slot_set(ctx, &root_slots[2], BK_TRUE) == BK_OK && bk_slot_get(ctx, &root_slots[2]) == BK_TRUE);
    assert(bk_slot_get(ctx, &root_slots[3]) == BK_UNDEFINED);
    bk_slot_clear(ctx, &root_slots[1]);
    assert(bk_slot_get(ctx, &root_slots[1]) == BK_UNDEFINED);
    assert(bk_slot_set(ctx, &root_slots[0], 12345) == BK_ERR_INVALID);

    bk_destroy(ctx);
    assert(nodes_freed >= before + 1);
    printf("tracing: PASS (%d nodes freed)\n", nodes_freed);
    return 0;
}
