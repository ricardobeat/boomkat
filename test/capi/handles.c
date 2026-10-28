/* Immediate handles and local scopes. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bk_value eval(bk_ctx ctx, const char *source) {
    bk_value result = bk_eval_ex(ctx, source, strlen(source), "handles.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(result)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(result));
    return result;
}

static bk_value echo(bk_ctx ctx, bk_value receiver, unsigned argc, const bk_value *argv, void *opaque) {
    (void)receiver; (void)opaque;
    return argc ? bk_dup_value(ctx, argv[0]) : BK_UNDEFINED;
}

static void test_immediates(void) {
    bk_ctx ctx = bk_create();
    assert(eval(ctx, "undefined") == BK_UNDEFINED);
    assert(eval(ctx, "null") == BK_NULL);
    assert(eval(ctx, "1 < 2") == BK_TRUE);
    assert(eval(ctx, "1 > 2") == BK_FALSE);
    assert(BK_BOOL(7) == BK_TRUE && BK_BOOL(0) == BK_FALSE);
    assert(bk_get_type(ctx, BK_UNDEFINED) == BK_TYPE_UNDEFINED);
    assert(bk_get_type(ctx, BK_NULL) == BK_TYPE_NULL);
    int b = 0;
    assert(bk_read_bool(ctx, BK_TRUE, &b) == BK_OK && b == 1);
    assert(bk_read_bool(ctx, BK_FALSE, &b) == BK_OK && b == 0);
    assert(bk_dup_value(ctx, BK_NULL) == BK_NULL);
    bk_free_value(ctx, BK_TRUE);
    /* Immediates are valid in every runtime. */
    bk_ctx other = bk_create();
    assert(bk_get_type(other, BK_TRUE) == BK_TYPE_BOOLEAN);
    bk_value object = eval(ctx, "({a: undefined, b: true})");
    assert(bk_get_property(ctx, object, "a", 1) == BK_UNDEFINED);
    assert(bk_get_property(ctx, object, "b", 1) == BK_TRUE);
    assert(bk_set_property(ctx, object, "c", 1, BK_NULL) == BK_OK);
    assert(bk_get_property(ctx, object, "c", 1) == BK_NULL);
    bk_value fn = bk_new_c_function(ctx, echo, "echo", 1, 0, NULL);
    bk_value args[1] = { BK_FALSE };
    assert(bk_call(ctx, fn, BK_UNDEFINED, args, 1) == BK_FALSE);
    assert(bk_get_exception(ctx) == BK_UNDEFINED);
    bk_free_value(ctx, fn);
    bk_free_value(ctx, object);
    bk_destroy(other);
    bk_destroy(ctx);
    puts("PASS: immediate handles");
}

int main(void) {
    test_immediates();
    return 0;
}
