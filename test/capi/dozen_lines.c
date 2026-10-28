#include <boomkat.h>
#include <stdio.h>
#include <assert.h>

#define CALLBACK(name) static bk_value name(bk_ctx js, bk_value self, unsigned argc, \
                                            const bk_value *argv, void *opaque)

CALLBACK(add) {
    (void)self; (void)opaque;
    double total = 0;
    for (unsigned i = 0; i < argc; i++) total += bk_to_number(js, argv[i]);
    return bk_new_number(js, total);
}

CALLBACK(describe) {
    (void)argv; (void)argc;
    char text[64];
    snprintf(text, sizeof text, "%s%s:%s", (const char *)opaque,
             bk_cstr(js, self, NULL), bk_cstr(js, bk_arg(js, 3), NULL));
    return bk_str(js, text);
}

CALLBACK(fail) {
    (void)self; (void)argc; (void)argv; (void)opaque;
    bk_new_number(js, 1);
    return bk_throw_error(js, BK_ERROR_RANGE, "nope");
}

CALLBACK(forward) {
    (void)self; (void)argc; (void)opaque;
    return bk_call(js, argv[0], BK_UNDEFINED, NULL, 0);
}

CALLBACK(nothing) { (void)js; (void)self; (void)argc; (void)argv; (void)opaque; return BK_UNDEFINED; }

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

    assert(bk_arg(js, 0) == 0 && bk_argc(js) == 0);
    assert(bk_exec(js, "globalThis.ran = true") == 0 && bk_exec(js, "throw 1") == 1);
    bk_destroy(js);

    bk_runtime runtime = bk_new_runtime(NULL);
    bk_ctx first = bk_new_context(runtime, NULL), second = bk_new_context(runtime, NULL);
    bk_destroy(second);
    assert(bk_exec(first, "1") == 0);
    bk_destroy(first);
    bk_free_runtime(runtime);
    puts("convenience API: PASS");
    return 0;
}
