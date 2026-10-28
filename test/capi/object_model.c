/* Construction, prototypes, equality, arrays, length, JSON and type codes. */
#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bk_value eval(bk_ctx ctx, const char *source) {
    bk_value r = bk_eval_ex(ctx, source, strlen(source), "om.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

int main(void) {
    bk_ctx ctx = bk_create();
    bk_value Point = eval(ctx, "class Point { constructor(x) { this.x = x; this.nt = new.target } }; Point");
    bk_value Sub = eval(ctx, "class Sub extends Point {}; Sub");
    bk_value arg = bk_new_number(ctx, 4);
    bk_value p = bk_construct(ctx, Point, &arg, 1, 0);
    assert(!bk_is_exception(p));
    bk_value x = bk_get_property(ctx, p, "x", 1);
    assert(bk_to_number(ctx, x) == 4);
    int is = 0;
    assert(bk_instanceof(ctx, p, Point, &is) == BK_OK && is == 1);
    assert(bk_instanceof(ctx, p, Sub, &is) == BK_OK && is == 0);
    bk_value q = bk_construct(ctx, Point, &arg, 1, Sub);
    bk_value nt = bk_get_property(ctx, q, "nt", 2);
    assert(bk_strict_equals(ctx, nt, Sub));
    assert(bk_instanceof(ctx, q, Sub, &is) == BK_OK && is == 1);
    bk_value DateCtor = eval(ctx, "Date");
    bk_value d = bk_construct(ctx, DateCtor, &arg, 1, 0);
    assert(bk_get_type(ctx, d) == BK_TYPE_OBJECT);
    bk_value thrower = eval(ctx, "(function T() { throw new TypeError('nope') })");
    assert(bk_construct(ctx, thrower, NULL, 0, 0) == BK_EXCEPTION && bk_get_error_code(ctx) == BK_ERR_THROW);
    bk_free_value(ctx, bk_get_exception(ctx));
    bk_value arrow = eval(ctx, "() => 1");
    assert(bk_construct(ctx, arrow, NULL, 0, 0) == BK_EXCEPTION && bk_get_error_code(ctx) == BK_ERR_TYPE);
    bk_value custom = eval(ctx, "({ [Symbol.hasInstance](v) { return v === 4 } })");
    assert(bk_instanceof(ctx, arg, custom, &is) == BK_OK && is == 1);
    assert(bk_instanceof(ctx, p, arg, &is) == BK_ERR_TYPE);

    /* Prototypes. */
    bk_value bare = bk_new_object_with_proto(ctx, BK_NULL);
    assert(bk_get_prototype(ctx, bare) == BK_NULL);
    bk_value proto = bk_get_prototype(ctx, p);
    bk_value Pproto = bk_get_property(ctx, Point, "prototype", 9);
    assert(bk_strict_equals(ctx, proto, Pproto));
    bk_value child = bk_new_object_with_proto(ctx, p);
    x = bk_get_property(ctx, child, "x", 1);
    assert(bk_to_number(ctx, x) == 4);
    assert(bk_set_prototype(ctx, bare, p) == BK_OK);
    assert(bk_set_prototype(ctx, p, child) == BK_ERR_THROW);   /* cycle */
    bk_free_value(ctx, bk_get_exception(ctx));
    bk_value frozen = eval(ctx, "Object.preventExtensions({})");
    assert(bk_set_prototype(ctx, frozen, BK_NULL) == BK_ERR_THROW);
    bk_free_value(ctx, bk_get_exception(ctx));
    assert(bk_new_object_with_proto(ctx, arg) == BK_EXCEPTION && bk_get_error_code(ctx) == BK_ERR_TYPE);

    /* Equality. */
    bk_value nan1 = bk_new_number(ctx, 0.0 / 0.0), nan2 = bk_new_number(ctx, 0.0 / 0.0);
    bk_value pz = bk_new_number(ctx, 0.0), nz = bk_new_number(ctx, -0.0);
    assert(!bk_strict_equals(ctx, nan1, nan2) && bk_same_value(ctx, nan1, nan2));
    assert(bk_strict_equals(ctx, pz, nz) && !bk_same_value(ctx, pz, nz));
    bk_value s1 = bk_new_string(ctx, "ab", 2), s2 = eval(ctx, "'a' + 'b'");
    assert(bk_strict_equals(ctx, s1, s2) && bk_same_value(ctx, s1, s2));
    assert(bk_strict_equals(ctx, BK_TRUE, BK_TRUE) && !bk_strict_equals(ctx, BK_NULL, BK_UNDEFINED));

    /* Arrays and length. */
    bk_value arr = eval(ctx, "[1, 2, 3]");
    bk_value parr = eval(ctx, "new Proxy([], {})");
    bk_value revoked = eval(ctx, "var r = Proxy.revocable([], {}); r.revoke(); r.proxy");
    assert(bk_is_array(ctx, arr) == 1 && bk_is_array(ctx, parr) == 1 && bk_is_array(ctx, p) == 0);
    assert(bk_is_array(ctx, revoked) == -1 && bk_get_error_code(ctx) == BK_ERR_THROW);
    bk_free_value(ctx, bk_get_exception(ctx));
    uint64_t len = 0;
    assert(bk_get_length(ctx, arr, &len) == BK_OK && len == 3);
    bk_value like = eval(ctx, "({ get length() { return '7.9' } })");
    assert(bk_get_length(ctx, like, &len) == BK_OK && len == 7);
    bk_value neg = eval(ctx, "({ length: -5 })");
    assert(bk_get_length(ctx, neg, &len) == BK_OK && len == 0);
    assert(bk_get_length(ctx, arg, &len) == BK_ERR_TYPE);

    /* JSON. */
    const char *text = "{\"a\":[1,\"x\",null],\"b\":true}";
    bk_value parsed = bk_json_parse(ctx, text, strlen(text));
    assert(!bk_is_exception(parsed));
    bk_value back = bk_json_stringify(ctx, parsed);
    assert(strcmp(bk_cstr(ctx, back, NULL), text) == 0);
    assert(bk_json_parse(ctx, "{bad", 4) == BK_EXCEPTION && bk_get_error_code(ctx) == BK_ERR_THROW);
    bk_value err = bk_get_exception(ctx);
    bk_value name = bk_get_property(ctx, err, "name", 4);
    assert(strcmp(bk_cstr(ctx, name, NULL), "SyntaxError") == 0);
    assert(bk_json_stringify(ctx, BK_UNDEFINED) == BK_UNDEFINED);
    bk_value cyc = eval(ctx, "var c = {}; c.c = c; c");
    assert(bk_json_stringify(ctx, cyc) == BK_EXCEPTION && bk_get_error_code(ctx) == BK_ERR_THROW);
    bk_free_value(ctx, bk_get_exception(ctx));

    /* Type codes. */
    assert(bk_get_type(ctx, eval(ctx, "Symbol()")) == BK_TYPE_SYMBOL);
    assert(bk_get_type(ctx, eval(ctx, "10n")) == BK_TYPE_BIGINT);
    assert(bk_get_type(ctx, eval(ctx, "Math.abs")) == BK_TYPE_FUNCTION);
    assert(bk_get_type(ctx, eval(ctx, "parseInt")) == BK_TYPE_FUNCTION);

    bk_destroy(ctx);
    puts("object_model: PASS");
    return 0;
}
