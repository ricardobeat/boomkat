/* bk_compile and bk_run_script. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bk_value run_from_callback(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)argc; (void)argv;
    return bk_run_script(ctx, *(bk_value *)opaque);
}

int main(void) {
    bk_ctx ctx = bk_create();
    const char *src = "globalThis.count = (globalThis.count || 0) + 1; count * 10";
    bk_value script = bk_compile(ctx, src, strlen(src), "counter.js", BK_EVAL_GLOBAL);
    assert(script && bk_get_type(ctx, script) == BK_TYPE_OBJECT);
    for (int i = 1; i <= 3; i++) {
        bk_value r = bk_run_script(ctx, script);
        assert(bk_to_number(ctx, r) == i * 10);
    }

    /* Each run is a fresh evaluation: function declarations rebind. */
    const char *decl = "function f() { return 'f' } f()";
    bk_value d = bk_compile(ctx, decl, strlen(decl), NULL, BK_EVAL_GLOBAL);
    for (int i = 0; i < 2; i++) assert(bk_get_type(ctx, bk_run_script(ctx, d)) == BK_TYPE_STRING);

    /* Strict scripts, and a runtime error per run. */
    const char *strict = "undeclared = 1";
    bk_value s = bk_compile(ctx, strict, strlen(strict), "strict.js", BK_EVAL_STRICT);
    assert(s);
    for (int i = 0; i < 2; i++) {
        assert(bk_run_script(ctx, s) == 0 && bk_get_error_code(ctx) == BK_ERR_THROW);
        bk_free_value(ctx, bk_get_exception(ctx));
    }

    /* Syntax errors fail at compile time with a position. */
    const char *bad = "let = ;";
    assert(bk_compile(ctx, bad, strlen(bad), "bad.js", BK_EVAL_STRICT) == 0);
    bk_error_info info;
    assert(bk_get_error_info(ctx, &info) == BK_OK && info.code == BK_ERR_SYNTAX && info.line == 1);
    assert(bk_compile(ctx, src, strlen(src), NULL, BK_EVAL_MODULE) == 0 && bk_get_error_code(ctx) == BK_ERR_INVALID);
    assert(bk_run_script(ctx, bk_new_number(ctx, 1)) == 0 && bk_get_error_code(ctx) == BK_ERR_TYPE);

    /* Another context runs it against its own globals. */
    bk_ctx other = bk_new_context(bk_get_runtime(ctx), NULL);
    assert(bk_to_number(other, bk_run_script(other, script)) == 10);

    /* From inside a callback, nested in a running script. */
    bk_value fn = bk_new_c_function(ctx, run_from_callback, "again", 0, 0, &script, NULL, NULL);
    bk_set_global_property(ctx, "again", 5, fn);
    const char *outer = "again() + 1";
    bk_value r = bk_eval_ex(ctx, outer, strlen(outer), NULL, BK_EVAL_GLOBAL);
    assert(bk_to_number(ctx, r) == 41);

    bk_destroy(ctx);
    puts("scripts: PASS");
    return 0;
}
