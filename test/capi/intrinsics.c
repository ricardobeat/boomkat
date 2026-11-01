/* Intrinsics, symbols and BigInt. */
#include "boomkat.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static bk_value eval(bk_ctx ctx, const char *src) {
    bk_value r = bk_eval_ex(ctx, src, strlen(src), "intrinsics.js", BK_EVAL_GLOBAL);
    if (bk_is_exception(r)) fprintf(stderr, "%s\n", bk_get_error_message(ctx));
    assert(!bk_is_exception(r));
    return r;
}

static void expect_string(bk_ctx ctx, bk_value v, const char *want) {
    char buf[128];
    assert(bk_read_string(ctx, v, buf, sizeof buf, NULL) == BK_OK);
    if (strcmp(buf, want)) fprintf(stderr, "got '%s' want '%s'\n", buf, want);
    assert(strcmp(buf, want) == 0);
}

int main(void) {
    bk_ctx ctx = bk_create();
    struct { bk_intrinsic which; const char *js; } pairs[] = {
        { BK_INTRINSIC_OBJECT_PROTOTYPE, "Object.prototype" },
        { BK_INTRINSIC_FUNCTION_PROTOTYPE, "Function.prototype" },
        { BK_INTRINSIC_ARRAY_PROTOTYPE, "Array.prototype" },
        { BK_INTRINSIC_ERROR_PROTOTYPE, "Error.prototype" },
        { BK_INTRINSIC_TYPE_ERROR_PROTOTYPE, "TypeError.prototype" },
        { BK_INTRINSIC_PROMISE_PROTOTYPE, "Promise.prototype" },
        { BK_INTRINSIC_ITERATOR_PROTOTYPE, "Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()))" },
        { BK_INTRINSIC_RANGE_ERROR_PROTOTYPE, "RangeError.prototype" },
        { BK_INTRINSIC_REFERENCE_ERROR_PROTOTYPE, "ReferenceError.prototype" },
        { BK_INTRINSIC_SYNTAX_ERROR_PROTOTYPE, "SyntaxError.prototype" },
        { BK_INTRINSIC_ASYNC_ITERATOR_PROTOTYPE, "Object.getPrototypeOf(Object.getPrototypeOf(Object.getPrototypeOf((async function*(){})())))" },
        { BK_INTRINSIC_GENERATOR_PROTOTYPE, "Object.getPrototypeOf(function*(){}).prototype" },
        { BK_INTRINSIC_STRING_PROTOTYPE, "String.prototype" },
        { BK_INTRINSIC_NUMBER_PROTOTYPE, "Number.prototype" },
        { BK_INTRINSIC_BOOLEAN_PROTOTYPE, "Boolean.prototype" },
        { BK_INTRINSIC_SYMBOL_PROTOTYPE, "Symbol.prototype" },
        { BK_INTRINSIC_BIGINT_PROTOTYPE, "BigInt.prototype" },
        { BK_INTRINSIC_DATE_PROTOTYPE, "Date.prototype" },
        { BK_INTRINSIC_REGEXP_PROTOTYPE, "RegExp.prototype" },
        { BK_INTRINSIC_MAP_PROTOTYPE, "Map.prototype" },
        { BK_INTRINSIC_SET_PROTOTYPE, "Set.prototype" },
        { BK_INTRINSIC_ARRAY_BUFFER_PROTOTYPE, "ArrayBuffer.prototype" },
        { BK_INTRINSIC_TYPED_ARRAY_PROTOTYPE, "Object.getPrototypeOf(Int8Array.prototype)" },
        { BK_INTRINSIC_GLOBAL_OBJECT, "globalThis" },
    };
    for (size_t i = 0; i < sizeof pairs / sizeof pairs[0]; i++) {
        bk_value got = bk_get_intrinsic(ctx, pairs[i].which);
        if (!bk_strict_equals(ctx, got, eval(ctx, pairs[i].js))) fprintf(stderr, "intrinsic %s\n", pairs[i].js);
        assert(bk_strict_equals(ctx, got, eval(ctx, pairs[i].js)));
    }
    assert(bk_get_intrinsic(ctx, (bk_intrinsic)99) == 0 && bk_get_error_code(ctx) == BK_ERR_INVALID);

    /* A second context has its own intrinsics. */
    bk_ctx other = bk_new_context(bk_get_runtime(ctx), NULL);
    assert(!bk_strict_equals(ctx, bk_get_intrinsic(other, BK_INTRINSIC_ARRAY_PROTOTYPE),
                             bk_get_intrinsic(ctx, BK_INTRINSIC_ARRAY_PROTOTYPE)));

    /* Symbols. */
    assert(bk_strict_equals(ctx, bk_get_well_known_symbol(ctx, BK_SYMBOL_ITERATOR), eval(ctx, "Symbol.iterator")));
    assert(bk_strict_equals(ctx, bk_get_well_known_symbol(ctx, BK_SYMBOL_ASYNC_DISPOSE), eval(ctx, "Symbol.asyncDispose")));
    assert(bk_strict_equals(ctx, bk_get_well_known_symbol(ctx, BK_SYMBOL_HAS_INSTANCE), eval(ctx, "Symbol.hasInstance")));
    bk_value s = bk_new_symbol(ctx, "d\xC3\xA9", 3);
    assert(bk_get_type(ctx, s) == BK_TYPE_SYMBOL);
    expect_string(ctx, bk_symbol_description(ctx, s), "d\xC3\xA9");
    assert(!bk_strict_equals(ctx, s, bk_new_symbol(ctx, "d\xC3\xA9", 3)));
    bk_value anon = bk_new_symbol(ctx, NULL, 0);
    assert(bk_symbol_description(ctx, anon) == BK_UNDEFINED);
    bk_value empty = bk_new_symbol(ctx, "", 0);
    expect_string(ctx, bk_symbol_description(ctx, empty), "");
    bk_set_global_property(ctx, "anon", 4, anon);
    assert(bk_to_bool(ctx, eval(ctx, "anon.description === undefined")));
    bk_value reg = bk_symbol_for(ctx, "app.key", 7);
    assert(bk_strict_equals(ctx, reg, eval(ctx, "Symbol.for('app.key')")));
    assert(bk_strict_equals(ctx, reg, bk_symbol_for(ctx, "app.key", 7)));
    assert(bk_symbol_description(ctx, bk_new_number(ctx, 1)) == 0 && bk_get_error_code(ctx) == BK_ERR_TYPE);

    /* BigInt. */
    bk_value b = bk_new_bigint_int64(ctx, INT64_MIN);
    assert(bk_get_type(ctx, b) == BK_TYPE_BIGINT);
    bk_set_global_property(ctx, "b", 1, b);
    assert(bk_to_bool(ctx, eval(ctx, "b === -(2n ** 63n)")));
    bk_value u = bk_new_bigint_uint64(ctx, UINT64_MAX);
    bk_set_global_property(ctx, "u", 1, u);
    assert(bk_to_bool(ctx, eval(ctx, "u === 2n ** 64n - 1n")));
    int64_t out; int lossless;
    assert(bk_read_bigint_int64(ctx, b, &out, &lossless) == BK_OK && out == INT64_MIN && lossless == 1);
    assert(bk_read_bigint_int64(ctx, u, &out, &lossless) == BK_OK && out == -1 && lossless == 0);
    assert(bk_read_bigint_int64(ctx, eval(ctx, "-5n"), &out, &lossless) == BK_OK && out == -5 && lossless == 1);
    assert(bk_read_bigint_int64(ctx, eval(ctx, "2n ** 64n + 7n"), &out, &lossless) == BK_OK && out == 7 && lossless == 0);
    assert(bk_read_bigint_int64(ctx, eval(ctx, "-(2n ** 200n) - 3n"), &out, &lossless) == BK_OK && out == -3 && lossless == 0);
    assert(bk_read_bigint_int64(ctx, bk_new_number(ctx, 1), &out, &lossless) == BK_ERR_TYPE);

    uint64_t words[3] = { 1, 0, 0x8000000000000000ull };
    bk_value big = bk_new_bigint_words(ctx, 1, words, 3);
    bk_set_global_property(ctx, "big", 3, big);
    assert(bk_to_bool(ctx, eval(ctx, "big === -(2n ** 191n + 1n)")));
    int neg; size_t count; uint64_t back[3];
    assert(bk_read_bigint_words(ctx, big, &neg, NULL, 0, &count) == BK_OK && count == 3 && neg == 1);
    assert(bk_read_bigint_words(ctx, big, &neg, back, 2, &count) == BK_ERR_FULL && count == 3);
    assert(bk_read_bigint_words(ctx, big, &neg, back, 3, &count) == BK_OK && count == 3);
    assert(back[0] == 1 && back[1] == 0 && back[2] == 0x8000000000000000ull);
    assert(bk_read_bigint_words(ctx, eval(ctx, "0n"), &neg, back, 3, &count) == BK_OK && count == 0 && neg == 0);
    assert(bk_read_bigint_words(ctx, eval(ctx, "-(2n ** 64n)"), &neg, back, 3, &count) == BK_OK && count == 2 && neg == 1 && back[0] == 0 && back[1] == 1);
    assert(bk_read_bigint_words(ctx, eval(ctx, "2n ** 63n"), &neg, back, 3, &count) == BK_OK && count == 1 && neg == 0 && back[0] == 0x8000000000000000ull);
    bk_value zero = bk_new_bigint_words(ctx, 1, NULL, 0);
    bk_set_global_property(ctx, "z", 1, zero);
    assert(bk_to_bool(ctx, eval(ctx, "z === 0n")));

    bk_destroy(ctx);
    puts("intrinsics: PASS");
    return 0;
}
