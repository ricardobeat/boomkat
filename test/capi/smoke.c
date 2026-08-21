/* smoke -- the smallest end-to-end check that the static archive links and
 * runs: open a context, eval "6*7", print 42. Driven by `make smoke` and by
 * the Linux CI suite. */
#include <boomkat.h>
#include <stdio.h>

int main(void) {
    bk_ctx ctx = bk_open();
    if (!ctx) return 1;
    bk_value v = bk_eval_str(ctx, "6*7");
    if (!v) { bk_close(ctx); return 1; }
    double n = 0;
    if (bk_read_number(ctx, v, &n) != BK_OK) { bk_free(ctx, v); bk_close(ctx); return 1; }
    printf("%g\n", n);
    bk_free(ctx, v);
    bk_close(ctx);
    return 0;
}
