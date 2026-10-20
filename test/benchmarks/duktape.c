/* Minimal Duktape v2.7.0 command-line runner for benchmarks */
#include <stdio.h>
#include <stdlib.h>
#include "duktape/src-separate/duk_config.h"
#include "duktape/src-separate/duktape.h"

static char *read_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    if (!buf) { fclose(f); return NULL; }
    fread(buf, 1, (size_t)sz, f);
    buf[sz] = '\0';
    fclose(f);
    *out_size = (size_t)sz;
    return buf;
}

/* Global print() — matches Duktape default builtin */
static int duk_bi_global_print(duk_context *ctx) {
    duk_idx_t nargs = duk_get_top(ctx);
    for (duk_idx_t i = 0; i < nargs; i++) {
        if (i > 0) putchar(' ');
        const char *s = duk_to_string(ctx, i);
        if (s) fputs(s, stdout);
    }
    putchar('\n');
    fflush(stdout);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <file.js>\n", argv[0]);
        return 1;
    }

    duk_context *ctx = duk_create_heap_default();
    if (!ctx) {
        fprintf(stderr, "Failed to create Duktape context\n");
        return 1;
    }

    /* Add print() builtin */
    duk_push_c_function(ctx, duk_bi_global_print, DUK_VARARGS);
    duk_put_global_string(ctx, "print");

    size_t sz = 0;
    char *src = read_file(argv[1], &sz);
    if (!src) {
        fprintf(stderr, "Cannot open file: %s\n", argv[1]);
        duk_destroy_heap(ctx);
        return 1;
    }

    int rc = duk_peval_lstring(ctx, src, sz);
    free(src);
    if (rc != 0) {
        fprintf(stderr, "eval failed: %s\n", duk_safe_to_string(ctx, -1));
        duk_pop(ctx);
        duk_destroy_heap(ctx);
        return 1;
    }
    duk_pop(ctx); /* pop result */

    duk_destroy_heap(ctx);
    return 0;
}
