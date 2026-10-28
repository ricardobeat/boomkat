/* smoke -- the smallest end-to-end check that the static archive links and
 * runs: open a context, eval "6*7", print 42. Driven by `make smoke` and by
 * the Linux CI suite. */
#include <boomkat.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    bk_ctx ctx = bk_new_context(bk_new_runtime(NULL));
    if (!ctx) return 1;
    bk_value v = bk_eval_ex(ctx, "6*7", strlen("6*7"), "<eval>", BK_EVAL_GLOBAL);
    if (!v) { bk_free_runtime(bk_get_runtime(ctx)); return 1; }
    double n = 0;
    if (bk_read_number(ctx, v, &n) != BK_OK) { bk_free_value(ctx, v); bk_free_runtime(bk_get_runtime(ctx)); return 1; }
    printf("%g\n", n);
    bk_free_value(ctx, v);
    v = bk_eval_ex(ctx, "typeof print + ',' + typeof console + ',' + typeof __resetGlobals + ',' + typeof parseInt", strlen("typeof print + ',' + typeof console + ',' + typeof __resetGlobals + ',' + typeof parseInt"), "<eval>", BK_EVAL_GLOBAL);
    const char *tools = v ? bk_to_cstring(ctx, v, NULL) : NULL;
    if (!tools || strcmp(tools, "undefined,undefined,undefined,function") != 0) {
        fprintf(stderr, "library exposed host runtime tools: %s\n", tools ? tools : bk_get_error_message(ctx));
        if (v) bk_free_value(ctx, v);
        bk_free_runtime(bk_get_runtime(ctx));
        return 1;
    }
    bk_free_cstring(ctx, tools);
    bk_free_value(ctx, v);
    bk_free_runtime(bk_get_runtime(ctx));
    return 0;
}
