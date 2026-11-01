/* Runtime options: a host allocator sees the runtime's heap allocations. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    size_t live_bytes;
    size_t live_blocks;
    size_t total_allocs;
} counter;

/* Each block carries its size in a 16-byte header. */
#define HEADER 16

static void *counting_alloc(void *opaque, size_t size) {
    counter *c = opaque;
    unsigned char *p = malloc(size + HEADER);
    if (!p) return NULL;
    memcpy(p, &size, sizeof size);
    c->live_bytes += size;
    c->live_blocks++;
    c->total_allocs++;
    return p + HEADER;
}

static void counting_free(void *opaque, void *ptr) {
    counter *c = opaque;
    if (!ptr) return;
    unsigned char *p = (unsigned char *)ptr - HEADER;
    size_t size;
    memcpy(&size, p, sizeof size);
    assert(c->live_bytes >= size && c->live_blocks > 0);
    c->live_bytes -= size;
    c->live_blocks--;
    free(p);
}

static void *counting_realloc(void *opaque, void *ptr, size_t size) {
    if (!ptr) return counting_alloc(opaque, size);
    if (size == 0) { counting_free(opaque, ptr); return NULL; }
    void *fresh = counting_alloc(opaque, size);
    if (!fresh) return NULL;
    size_t old;
    memcpy(&old, (unsigned char *)ptr - HEADER, sizeof old);
    memcpy(fresh, ptr, old < size ? old : size);
    counting_free(opaque, ptr);
    return fresh;
}

int main(void) {
    counter c = {0, 0, 0};
    bk_runtime_options options = {counting_alloc, counting_realloc, counting_free, &c, NULL};
    bk_runtime runtime = bk_new_runtime(&options);
    assert(runtime);
    assert(c.total_allocs > 0 && c.live_bytes > 0);
    bk_ctx ctx = bk_new_context(runtime, NULL);
    size_t before = c.total_allocs;
    const char *src = "var a = []; for (var i = 0; i < 10000; i++) a.push({i: i, s: 'x' + i}); a.length";
    bk_value v = bk_eval_ex(ctx, src, strlen(src), "options.js", BK_EVAL_GLOBAL);
    assert(!bk_is_exception(v) && bk_to_number(ctx, v) == 10000);
    bk_free_value(ctx, v);
    assert(c.total_allocs > before);

    size_t live = c.live_bytes;
    char *block = bk_alloc(runtime, 100);
    assert(block && c.live_bytes == live + 100);
    block = bk_realloc(runtime, block, 300);
    assert(block && c.live_bytes == live + 300);
    bk_free_memory(runtime, block);
    assert(c.live_bytes == live);
    block = bk_realloc(runtime, NULL, 8);
    assert(block && c.live_bytes == live + 8);
    assert(bk_realloc(runtime, block, 0) == NULL && c.live_bytes == live);

    bk_free_context(ctx);
    bk_free_runtime(runtime);
    /* Every block the runtime took from the host went back to the host. */
    if (c.live_blocks != 0) fprintf(stderr, "%zu blocks, %zu bytes not returned\n", c.live_blocks, c.live_bytes);
    assert(c.live_blocks == 0 && c.live_bytes == 0);

    /* The allocator functions come as a set. */
    bk_runtime_options partial = {counting_alloc, NULL, NULL, &c, NULL};
    assert(bk_new_runtime(&partial) == NULL);
    bk_runtime plain = bk_new_runtime(NULL);
    assert(plain);
    bk_free_runtime(plain);
    puts("runtime options: PASS");
    return 0;
}
