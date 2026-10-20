#include <boomkat.h>
#include <stdio.h>

static bk_value add(bk_ctx ctx, bk_value receiver, unsigned argc,
                    const bk_value *argv, void *opaque) {
    (void)receiver; (void)opaque;
    double total = 0;
    for (unsigned i = 0; i < argc; i++) {
        double value;
        if (bk_read_number(ctx, argv[i], &value) != BK_OK)
            return bk_throw_error(ctx, BK_ERROR_TYPE, "add expects numbers");
        total += value;
    }
    return bk_new_number(ctx, total);
}

static bk_value twice(bk_ctx ctx, bk_value receiver, unsigned argc,
                      const bk_value *argv, void *opaque) {
    (void)receiver; (void)opaque;
    if (argc < 2) return bk_throw_error(ctx, BK_ERROR_TYPE, "twice expects a function and value");
    bk_value first = bk_call(ctx, argv[0], 0, &argv[1], 1);
    if (bk_is_exception(first)) return BK_EXCEPTION;
    bk_value result = bk_call(ctx, argv[0], 0, &first, 1);
    bk_free_value(ctx, first);
    return result;
}

int main(void) {
    bk_runtime runtime = bk_new_runtime();
    bk_ctx ctx = bk_new_context(runtime);
    if (!ctx) { bk_free_runtime(runtime); return 1; }
    const bk_fn_def functions[] = {{"add", add, 2, 0, NULL}, {"twice", twice, 2, 0, NULL}, BK_FN_END};
    bk_set_function_list(ctx, 0, functions);
    const char *source = "add(40,2) + twice(x => x*2, 3)";
    bk_value result = bk_eval(ctx, source, strlen(source), "host.js", BK_EVAL_GLOBAL);
    int failed = bk_is_exception(result);
    if (failed) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    else printf("%.0f\n", bk_to_number(ctx, result));
    bk_free_value(ctx, result);
    bk_free_context(ctx);
    bk_free_runtime(runtime);
    return failed;
}
