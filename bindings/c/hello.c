#include <boomkat.h>
#include <stdio.h>

static bk_value print(bk_ctx ctx, bk_value receiver, unsigned argc,
                      const bk_value *argv, void *output) {
    (void)receiver;
    if (argc) {
        const char *text = bk_to_cstring(ctx, argv[0], NULL);
        if (!text) return BK_EXCEPTION;
        fprintf(output, "%s\n", text);
        bk_free_cstring(ctx, text);
    }
    return bk_new_undefined(ctx);
}

int main(void) {
    bk_runtime runtime = bk_new_runtime();
    bk_ctx ctx = bk_new_context(runtime);
    if (!ctx) { bk_free_runtime(runtime); return 1; }
    const bk_fn_def functions[] = {{"print", print, 1, 0, stdout}, BK_FN_END};
    bk_set_function_list(ctx, 0, functions);
    const char *source = "print('Hello, world from Boomkat!')";
    bk_value result = bk_eval(ctx, source, strlen(source), "hello.js", BK_EVAL_GLOBAL);
    int failed = bk_is_exception(result);
    if (failed) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    bk_free_value(ctx, result);
    bk_free_context(ctx);
    bk_free_runtime(runtime);
    return failed;
}
