/* smoke -- the smallest end-to-end check that the static archive links and
 * runs: open a context, eval "6*7", print 42. Driven by `make smoke` and by
 * the Linux CI suite. */
#include <boomkat.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    bk_ctx ctx = bk_open();
    if (!ctx) return 1;
    bk_value v = bk_eval_str(ctx, "6*7");
    if (!v) { bk_close(ctx); return 1; }
    double n = 0;
    if (bk_read_number(ctx, v, &n) != BK_OK) { bk_free(ctx, v); bk_close(ctx); return 1; }
    printf("%g\n", n);
    bk_free(ctx, v);
    v = bk_eval_str(ctx, "typeof print + ',' + typeof console + ',' + typeof __resetGlobals + ',' + typeof parseInt");
    if (!v || strcmp(bk_cstr(ctx, v, NULL), "undefined,undefined,undefined,function") != 0) {
        fprintf(stderr, "library exposed host runtime tools: %s\n", v ? bk_cstr(ctx, v, NULL) : bk_error(ctx));
        if (v) bk_free(ctx, v);
        bk_close(ctx);
        return 1;
    }
    bk_free(ctx, v);
    bk_close(ctx);
    return 0;
}
