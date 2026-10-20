#include <boomkat.h>
#include <stdio.h>
#include <assert.h>

int main(void) {
    bk_runtime runtime = bk_new_runtime();
    bk_ctx ctx = bk_new_context(runtime);
    if (!ctx) { bk_free_runtime(runtime); return 1; }
    const char *source = "[1,2,3].map(x => x*x).join(',')";
    bk_value result = bk_eval(ctx, source, strlen(source), "example.js", BK_EVAL_GLOBAL);
    const char *text = result ? bk_to_cstring(ctx, result, NULL) : NULL;
    if (text) { puts(text); assert(strcmp(text, "1,4,9") == 0); }
    else fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    int failed = text == NULL;
    bk_free_cstring(ctx, text);
    bk_free_value(ctx, result);
    bk_free_context(ctx);
    bk_free_runtime(runtime);
    return failed;
}
