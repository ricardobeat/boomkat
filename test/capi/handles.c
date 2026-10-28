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
    (void)ctx; (void)receiver; (void)opaque;
    return argc ? argv[0] : BK_UNDEFINED;
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

#define IS_LOCAL(v) ((((v) >> 47) & 1u) != 0)

/* Creates 1,000 values, opens a scope it leaves open, and reads its argument
 * after opening it. */
static bk_value churn(bk_ctx ctx, bk_value receiver, unsigned argc, const bk_value *argv, void *opaque) {
    (void)receiver; (void)opaque;
    assert(argc == 1);
    assert(bk_scope_current(ctx) != 0);
    bk_value last = BK_UNDEFINED;
    for (int i = 0; i < 1000; i++) {
        last = bk_new_number(ctx, i);
        assert(IS_LOCAL(last));
    }
    bk_scope_open(ctx);
    bk_value inner = bk_new_object(ctx);
    assert(IS_LOCAL(inner));
    assert(bk_arg(ctx, 0) == argv[0]);
    assert(bk_arg(ctx, 5) == BK_UNDEFINED);
    double n = 0;
    assert(bk_read_number(ctx, argv[0], &n) == BK_OK);
    bk_value sum = bk_new_number(ctx, n + bk_to_number(ctx, last));
    return sum;
}

static bk_value saved;

/* Keeps its argument past the call with bk_dup_value. */
static bk_value keep(bk_ctx ctx, bk_value receiver, unsigned argc, const bk_value *argv, void *opaque) {
    (void)receiver; (void)opaque; (void)argc;
    saved = bk_dup_value(ctx, argv[0]);
    assert(!IS_LOCAL(saved));
    return BK_UNDEFINED;
}

/* Calls back into JS; the nested call's locals die with it. */
static bk_value nest(bk_ctx ctx, bk_value receiver, unsigned argc, const bk_value *argv, void *opaque) {
    (void)receiver; (void)opaque;
    if (argc == 0) return bk_new_string(ctx, "leaf", 4);
    bk_value got = bk_call(ctx, argv[0], BK_UNDEFINED, NULL, 0);
    if (bk_is_exception(got)) return BK_EXCEPTION;
    assert(IS_LOCAL(got));
    return got;
}

static void test_scopes(void) {
    bk_ctx ctx = bk_create();
    assert(bk_scope_current(ctx) == 0);
    bk_value root = bk_new_number(ctx, 1);
    assert(!IS_LOCAL(root));

    bk_scope outer = bk_scope_open(ctx);
    assert(outer != 0 && bk_scope_current(ctx) == outer);
    bk_value first = BK_UNDEFINED, last = BK_UNDEFINED;
    for (int i = 0; i < 100000; i++) {
        bk_value v = bk_new_number(ctx, i);
        assert(IS_LOCAL(v));
        if (i == 0) first = v;
        last = v;
    }
    assert(bk_to_number(ctx, first) == 0 && bk_to_number(ctx, last) == 99999);
    bk_value copy = bk_scope_local(ctx, root);
    assert(IS_LOCAL(copy) && bk_to_number(ctx, copy) == 1);

    bk_scope inner = bk_scope_open(ctx);
    bk_value text = bk_new_string(ctx, "escaped", 7);
    assert(IS_LOCAL(text));
    bk_value escaped = bk_scope_close_escape(ctx, inner, text);
    assert(IS_LOCAL(escaped) && bk_scope_current(ctx) == outer);
    double n;
    assert(bk_read_number(ctx, text, &n) == BK_ERR_INVALID);
    assert(bk_string_length(ctx, escaped) == 7);

    bk_value object = bk_new_object(ctx);
    bk_value kept = bk_scope_close_escape(ctx, outer, object);
    assert(!IS_LOCAL(kept) && bk_get_type(ctx, kept) == BK_TYPE_OBJECT);
    assert(bk_scope_current(ctx) == 0);
    assert(bk_read_number(ctx, last, &n) == BK_ERR_INVALID);
    assert(bk_read_number(ctx, root, &n) == BK_OK && n == 1);
    /* Closing a scope that is gone is ignored. */
    bk_scope_close(ctx, outer);
    assert(bk_scope_close_escape(ctx, outer, root) == BK_EXCEPTION);
    assert(bk_get_error_code(ctx) == BK_ERR_INVALID);

    /* Closing an outer scope closes the scopes inside it. */
    bk_scope a = bk_scope_open(ctx);
    bk_scope_open(ctx);
    bk_scope_open(ctx);
    bk_scope_close(ctx, a);
    assert(bk_scope_current(ctx) == 0);

    /* A scope holds at most 131,072 values. */
    bk_scope big = bk_scope_open(ctx);
    unsigned made = 0;
    for (;;) {
        bk_value v = bk_new_number(ctx, made + 0.5);
        if (bk_is_exception(v)) break;
        made++;
    }
    assert(made == 131072 && bk_get_error_code(ctx) == BK_ERR_FULL);
    bk_scope_close(ctx, big);

    bk_value fn = bk_new_c_function(ctx, churn, "churn", 1, 0, NULL);
    bk_set_global_property(ctx, "churn", 5, fn);
    bk_free_value(ctx, fn);
    fn = bk_new_c_function(ctx, keep, "keep", 1, 0, NULL);
    bk_set_global_property(ctx, "keep", 4, fn);
    bk_free_value(ctx, fn);
    fn = bk_new_c_function(ctx, nest, "nest", 1, 0, NULL);
    bk_set_global_property(ctx, "nest", 4, fn);
    bk_free_value(ctx, fn);
    fn = bk_new_c_function(ctx, echo, "echo", 1, 0, NULL);
    bk_set_global_property(ctx, "echo", 4, fn);
    bk_free_value(ctx, fn);

    bk_value r = eval(ctx, "churn(1) + churn(2)");
    assert(!IS_LOCAL(r) && bk_to_number(ctx, r) == 2001);
    bk_free_value(ctx, r);
    assert(bk_scope_current(ctx) == 0);
    r = eval(ctx, "var o = {}; echo(o) === o && echo() === undefined");
    assert(r == BK_TRUE);
    r = eval(ctx, "keep({tag: 'saved'}); nest(() => nest(() => nest()))");
    char buf[8];
    assert(bk_read_string(ctx, r, buf, sizeof buf, NULL) == BK_OK && strcmp(buf, "leaf") == 0);
    bk_free_value(ctx, r);
    r = eval(ctx, "for (var i = 0; i < 200; i++) churn(i); 1");
    bk_free_value(ctx, r);
    bk_value tag = bk_get_property(ctx, saved, "tag", 3);
    assert(bk_read_string(ctx, tag, buf, sizeof buf, NULL) == BK_OK && strcmp(buf, "saved") == 0);
    bk_free_value(ctx, tag);
    bk_free_value(ctx, saved);
    bk_free_value(ctx, kept);
    bk_free_value(ctx, root);
    /* A scope left open at teardown is released with the runtime. */
    bk_scope_open(ctx);
    bk_new_object(ctx);
    bk_destroy(ctx);
    puts("PASS: local scopes");
}

int main(void) {
    test_immediates();
    test_scopes();
    return 0;
}
