/* GC control, external memory, heap stats and the byte-counted heap limit. */
#include "boomkat.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static bk_value eval(bk_ctx ctx, const char *src) {
    return bk_eval_ex(ctx, src, strlen(src), "gc.js", BK_EVAL_GLOBAL);
}

static uint64_t now_ns(void) {
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static bk_heap_stats stats(bk_runtime rt) {
    bk_heap_stats s;
    assert(bk_get_heap_stats(rt, &s) == BK_OK);
    return s;
}

int main(void) {
    /* A counting runtime with a 16 MiB budget. */
    bk_runtime_options options = { 0 };
    options.heap_limit = 16u << 20;
    bk_runtime rt = bk_new_runtime(&options);
    bk_ctx ctx = bk_new_context(rt);
    bk_heap_stats s = stats(rt);
    assert(s.heap_bytes > 0 && s.heap_limit == 16u << 20);

    /* A full collection reclaims garbage and counts as a cycle. */
    bk_value v = eval(ctx, "globalThis.junk = []; for (let i = 0; i < 20000; i++) junk.push({ i }); 1");
    assert(v);
    uint64_t full = stats(rt).heap_bytes;
    eval(ctx, "junk = null");
    uint32_t cycles = stats(rt).gc_cycles;
    bk_gc(rt, BK_GC_FULL);
    s = stats(rt);
    assert(s.gc_cycles > cycles && s.heap_bytes < full);
    bk_gc(rt, BK_GC_MINOR);
    assert(stats(rt).gc_cycles > s.gc_cycles);

    /* Crossing the budget terminates uncatchably with BK_ERR_NOMEM. */
    v = eval(ctx, "let keep = []; try { for (;;) keep.push({ a: 1, b: 2, c: [1, 2, 3] }) } catch (e) { 'caught' }");
    assert(v == 0 && bk_get_error_code(ctx) == BK_ERR_NOMEM);
    printf("over limit: %s\n", bk_get_error_message(ctx));
    /* The runtime stays usable. */
    v = eval(ctx, "6 * 7");
    assert(v && bk_to_number(ctx, v) == 42);
    s = stats(rt);
    assert(s.heap_bytes <= s.heap_limit);

    /* One oversized block is refused, then the script is terminated. */
    v = eval(ctx, "try { new ArrayBuffer(64 * 1024 * 1024); 'made' } catch (e) { for (;;) {} }");
    assert(v == 0 && bk_get_error_code(ctx) == BK_ERR_NOMEM);
    v = eval(ctx, "1 + 1");
    assert(v && bk_to_number(ctx, v) == 2);

    /* Raising the limit lets the work finish; removing it reports none. */
    assert(bk_set_heap_limit(rt, 0) == BK_OK && stats(rt).heap_limit == 0);
    v = eval(ctx, "{ let a = []; for (let i = 0; i < 400000; i++) a.push({ i }); a.length }");
    assert(v && bk_to_number(ctx, v) == 400000);
    assert(bk_set_heap_limit(rt, 16u << 20) == BK_OK);
    bk_gc(rt, BK_GC_FULL);

    /* External memory is reported. */
    bk_add_external_memory(rt, 1 << 20);
    assert(stats(rt).external_bytes == 1 << 20);
    bk_add_external_memory(rt, -(1 << 20));
    assert(stats(rt).external_bytes == 0);

    /* Inhibited, allocation does not collect; bk_gc still does. */
    cycles = stats(rt).gc_cycles;
    bk_gc_inhibit(rt, 1);
    eval(ctx, "{ for (let i = 0; i < 100000; i++) ({ i }) }");
    assert(stats(rt).gc_cycles == cycles);
    bk_gc(rt, BK_GC_FULL);
    assert(stats(rt).gc_cycles == cycles + 1);
    bk_gc_inhibit(rt, 0);

    /* Stepping finishes a cycle in bounded slices. */
    eval(ctx, "globalThis.junk = []; for (let i = 0; i < 50000; i++) junk.push({ i }); junk = null");
    cycles = stats(rt).gc_cycles;
    int slices = 0;
    uint64_t worst = 0;
    do {
        uint64_t t0 = now_ns();
        int busy = bk_gc_step(rt, 200000);
        uint64_t took = now_ns() - t0;
        if (took > worst) worst = took;
        slices++;
        if (!busy) break;
    } while (slices < 100000);
    assert(stats(rt).gc_cycles > cycles);
    printf("gc_step: %d slices, longest %llu us\n", slices, (unsigned long long)(worst / 1000));

    /* Live handles are counted. */
    uint32_t live = stats(rt).live_handles;
    bk_value obj = bk_new_object(ctx);
    assert(stats(rt).live_handles == live + 1);
    bk_free_value(ctx, obj);

    bk_free_context(ctx);
    bk_free_runtime(rt);

    /* A runtime that does not count bytes has no limit to set. */
    bk_ctx plain = bk_create();
    assert(bk_set_heap_limit(bk_get_runtime(plain), 1 << 20) == BK_ERR_INVALID);
    assert(stats(bk_get_runtime(plain)).heap_bytes == 0);
    bk_destroy(plain);
    puts("gc_control: PASS");
    return 0;
}
