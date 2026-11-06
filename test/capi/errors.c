/* Error values, diagnostics formatting and stacks in bk_error_info. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int getter_ran;

static bk_value mark(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)ctx; (void)this_value; (void)argc; (void)argv; (void)opaque;
    getter_ran = 1;
    return BK_UNDEFINED;
}

static void expect_describe(bk_ctx ctx, bk_value v, const char *want) {
    char buf[256];
    size_t len = 0;
    assert(bk_describe(ctx, v, buf, sizeof buf, &len) == BK_OK);
    if (strcmp(buf, want) != 0) fprintf(stderr, "describe: got '%s' want '%s'\n", buf, want);
    assert(strcmp(buf, want) == 0 && len == strlen(want));
}

static bk_value eval(bk_ctx ctx, const char *src) {
    return bk_eval_ex(ctx, src, strlen(src), "errors.js", BK_EVAL_GLOBAL);
}

/* coerce(v): bk_to_string, or bk_to_number with a second argument, rethrowing what the coercion threw. */
static bk_value coerce(bk_ctx ctx, bk_value this_value, unsigned argc, const bk_value *argv, void *opaque) {
    (void)this_value; (void)opaque;
    if (argc > 1) {
        double d = bk_to_number(ctx, argv[0]);
        if (bk_get_error_code(ctx) == BK_ERR_THROW) return bk_throw(ctx, bk_get_exception(ctx));
        return bk_new_number(ctx, d);
    }
    bk_value s = bk_to_string(ctx, argv[0]);
    if (bk_is_exception(s)) return bk_throw(ctx, bk_get_exception(ctx));
    return s;
}

static void expect_eval_string(bk_ctx ctx, const char *src, const char *want) {
    bk_value r = eval(ctx, src);
    assert(!bk_is_exception(r));
    const char *got = bk_cstr(ctx, r, NULL);
    if (!got || strcmp(got, want) != 0) fprintf(stderr, "%s: got %s, want %s\n", src, got ? got : "(null)", want);
    assert(got && strcmp(got, want) == 0);
    bk_free_value(ctx, r);
}

int main(void) {
    bk_ctx ctx = bk_create();

    bk_value err = bk_new_error(ctx, BK_ERROR_RANGE, "too far \xF0\x9F\x9A\x80");
    assert(err != 0 && bk_get_type(ctx, err) == BK_TYPE_OBJECT);
    bk_value RangeError = eval(ctx, "RangeError");
    int is = 0;
    assert(bk_instanceof(ctx, err, RangeError, &is) == BK_OK && is == 1);
    assert(bk_get_exception(ctx) == BK_UNDEFINED);
    expect_describe(ctx, err, "RangeError: too far \xF0\x9F\x9A\x80");
    bk_value stack = bk_get_property(ctx, err, "stack", 5);
    assert(bk_get_type(ctx, stack) == BK_TYPE_STRING);
    assert(bk_new_error(ctx, (bk_error_kind)9, "x") == 0 && bk_get_error_code(ctx) == BK_ERR_INVALID);
    assert(bk_new_error(ctx, BK_ERROR, "\xFF") == 0 && bk_get_error_code(ctx) == BK_ERR_ENCODING);
    bk_value bare = bk_new_error(ctx, BK_ERROR_TYPE, NULL);
    expect_describe(ctx, bare, "TypeError");

    expect_describe(ctx, BK_UNDEFINED, "undefined");
    expect_describe(ctx, BK_TRUE, "true");
    expect_describe(ctx, bk_new_number(ctx, 1.5), "1.5");
    expect_describe(ctx, eval(ctx, "Symbol('s')"), "Symbol(s)");
    expect_describe(ctx, eval(ctx, "123456789012345678901234567890n"), "123456789012345678901234567890n");
    expect_describe(ctx, eval(ctx, "[1]"), "[object Array]");
    expect_describe(ctx, eval(ctx, "(function f() {})"), "[Function: f]");

    /* No getters, traps or toString run. */
    bk_value spy = bk_new_c_function(ctx, mark, "spy", 0, 0, NULL, NULL, NULL);
    bk_set_global_property(ctx, "spy", 3, spy);
    expect_describe(ctx, eval(ctx, "({ get message() { spy(); return 'm' }, toString() { spy(); return 'x' } })"),
                    "[object Object]");
    expect_describe(ctx, eval(ctx, "new Proxy({}, { get() { spy(); return 'p' } })"), "[object Object]");
    assert(!getter_ran);

    /* Measuring, and a full buffer, keep the pending exception. */
    assert(eval(ctx, "function inner() { throw new TypeError('deep') } function outer() { inner() } outer()") == BK_EXCEPTION);
    bk_error_info info;
    assert(bk_get_error_info(ctx, &info) == BK_OK && info.code == BK_ERR_THROW);
    assert(info.stack != NULL && strstr(info.stack, "TypeError: deep") && strstr(info.stack, "inner") && strstr(info.stack, "outer"));
    size_t need = 0;
    bk_value pending = bk_get_exception(ctx);
    assert(eval(ctx, "throw new Error('again')") == BK_EXCEPTION);
    assert(bk_describe(ctx, pending, NULL, 0, &need) == BK_OK && need == strlen("TypeError: deep"));
    char small[4];
    assert(bk_describe(ctx, pending, small, sizeof small, &need) == BK_ERR_FULL && strcmp(small, "Typ") == 0);
    assert(bk_get_error_code(ctx) == BK_ERR_THROW && strcmp(bk_get_error_message(ctx), "Error: again") == 0);
    bk_value again = bk_get_exception(ctx);
    expect_describe(ctx, again, "Error: again");

    /* A non-Error throw has no stack. */
    assert(eval(ctx, "throw 7") == BK_EXCEPTION);
    assert(bk_get_error_info(ctx, &info) == BK_OK && info.stack == NULL);
    bk_free_value(ctx, bk_get_exception(ctx));

    /* An uncaught throw leaves the next script's native getters working. */
    bk_value size = eval(ctx, "new Map([[1, 2]]).size");
    assert(size && bk_to_number(ctx, size) == 1);

    /* Coercions that run user code report its throw, also inside a callback. */
    bk_register_fn(ctx, 0, "coerce", coerce, 1, 0, NULL);
    expect_eval_string(ctx, "try { coerce({ toString() { throw new RangeError('s'); } }); 'none' } catch (e) { e.message }", "s");
    expect_eval_string(ctx, "try { coerce({ [Symbol.toPrimitive]() { return {}; } }); 'none' } catch (e) { e.name }", "TypeError");
    expect_eval_string(ctx, "try { coerce(Symbol()); 'none' } catch (e) { e.name }", "TypeError");
    expect_eval_string(ctx, "try { coerce({ valueOf() { throw 3; } }, 1); 'none' } catch (e) { 'caught ' + e }", "caught 3");
    bk_value thrower = eval(ctx, "({ toString() { throw new Error('top'); } })");
    assert(bk_is_exception(bk_to_string(ctx, thrower)));
    assert(bk_get_error_code(ctx) == BK_ERR_THROW && strcmp(bk_get_error_message(ctx), "Error: top") == 0);
    bk_free_value(ctx, bk_get_exception(ctx));
    bk_free_value(ctx, thrower);

    bk_destroy(ctx);
    puts("errors: PASS");
    return 0;
}
