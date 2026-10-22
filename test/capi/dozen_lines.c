#include <boomkat.h>
#include <stdio.h>
#include <assert.h>

static void add(bk_ctx js, void *opaque) {
    (void)opaque;
    double total = 0;
    for (unsigned i = 0; i < bk_argc(js); i++) total += bk_to_number(js, bk_arg(js, i));
    bk_return_number(js, total);
}

static void describe(bk_ctx js, void *prefix) {
    char text[64];
    snprintf(text, sizeof text, "%s%s:%s", (const char *)prefix,
             bk_cstr(js, bk_this(js), NULL), bk_cstr(js, bk_arg(js, 3), NULL));
    bk_return_str(js, text);
}

static void fail(bk_ctx js, void *opaque) {
    (void)opaque;
    bk_return_number(js, 1);
    bk_throw_error(js, BK_ERROR_RANGE, "nope");
}

static void forward(bk_ctx js, void *opaque) {
    (void)opaque;
    bk_value result = bk_call(js, bk_arg(js, 0), 0, NULL, 0);
    if (!bk_is_exception(result)) bk_return(js, result);
    bk_free(js, result);
}

static void nothing(bk_ctx js, void *opaque) { (void)js; (void)opaque; }

static void expect(bk_ctx js, const char *source, const char *want) {
    bk_value value = bk_eval(js, source);
    const char *got = bk_is_exception(value) ? bk_error(js) : bk_cstr(js, value, NULL);
    if (strcmp(got, want) != 0) { fprintf(stderr, "%s: got '%s', want '%s'\n", source, got, want); assert(0); }
    bk_free(js, value);
}

int main(void) {
    bk_ctx js = bk_create();
    assert(js);
    bk_value v = bk_eval(js, "[1,2,3].map(x => x*x).join(',')");
    assert(strcmp(bk_cstr(js, v, NULL), "1,4,9") == 0);
    bk_free(js, v);

    assert(bk_register_fn(js, 0, "add", add, 2, 0, NULL) == BK_OK);
    assert(bk_register_fn(js, 0, "fail", fail, 0, 0, NULL) == BK_OK);
    assert(bk_register_fn(js, 0, "forward", forward, 1, 0, NULL) == BK_OK);
    assert(bk_register_fn(js, 0, "nothing", nothing, 0, 0, NULL) == BK_OK);
    bk_value proto = bk_eval(js, "String.prototype");
    assert(bk_register_fn(js, proto, "describe", describe, 0, 0, "pre:") == BK_OK);
    bk_free(js, proto);

    expect(js, "add(40, 2, '3')", "45");
    expect(js, "add.length + add.name", "2add");
    expect(js, "'abc'.describe()", "pre:abc:undefined");
    expect(js, "'x'.describe(1, 2, 3, 4)", "pre:x:4");
    expect(js, "typeof nothing()", "undefined");
    expect(js, "try { fail() } catch (e) { e instanceof RangeError && e.message }", "nope");
    expect(js, "forward(() => 7)", "7");
    expect(js, "try { forward(() => { throw 'up' }) } catch (e) { e }", "up");
    expect(js, "forward(() => add(1, forward(() => 2)))", "3");

    const char *ring[4];
    for (int i = 0; i < 4; i++) {
        bk_value n = bk_new_number(js, i);
        ring[i] = bk_cstr(js, n, NULL);
        bk_free(js, n);
    }
    assert(!strcmp(ring[0], "0") && !strcmp(ring[1], "1") && !strcmp(ring[2], "2") && !strcmp(ring[3], "3"));

    bk_value obj = bk_eval(js, "({})"), answer = bk_new_number(js, 42);
    assert(bk_set(js, obj, "answer", answer) == BK_OK);
    assert(bk_set_global(js, "box", obj) == BK_OK);
    expect(js, "box.answer", "42");
    bk_value got = bk_get(js, obj, "answer");
    assert(bk_is_number(js, got) && bk_to_number(js, got) == 42);
    bk_free(js, got);
    bk_free(js, answer);
    bk_free(js, obj);

    assert(bk_arg(js, 0) == 0 && bk_argc(js) == 0 && bk_return(js, 0) == BK_ERR_INVALID);
    assert(bk_exec(js, "globalThis.ran = true") == 0 && bk_exec(js, "throw 1") == 1);
    bk_destroy(js);

    bk_runtime runtime = bk_new_runtime();
    bk_ctx first = bk_new_context(runtime), second = bk_new_context(runtime);
    bk_destroy(second);
    assert(bk_exec(first, "1") == 0);
    bk_destroy(first);
    bk_free_runtime(runtime);
    puts("convenience API: PASS");
    return 0;
}
