#include "boomkat.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static bk_ctx ctx;

static bk_value eval(const char *src) {
    bk_value v = bk_eval_ex(ctx, src, strlen(src), "<eval>", BK_EVAL_GLOBAL);
    if (!v) fprintf(stderr, "eval failed: %s\n", bk_get_error_message(ctx));
    assert(v);
    return v;
}

static void expect_units(bk_value v, const uint16_t *want, size_t n) {
    size_t len = 0;
    uint16_t buf[64];
    assert(bk_string_length(ctx, v) == n);
    assert(bk_read_string_utf16(ctx, v, NULL, 0, &len) == BK_OK && len == n);
    assert(bk_read_string_utf16(ctx, v, buf, 64, &len) == BK_OK && len == n);
    assert(memcmp(buf, want, n * sizeof *want) == 0);
    if (n > 0) {
        assert(bk_read_string_utf16(ctx, v, buf, n - 1, &len) == BK_ERR_FULL && len == n);
    }
}

static void expect_utf8(bk_value v, bk_utf8_mode mode, const char *want) {
    size_t n = strlen(want), len = 0;
    char buf[64];
    assert(bk_read_string_utf8(ctx, v, mode, NULL, 0, &len) == BK_OK && len == n);
    assert(bk_read_string_utf8(ctx, v, mode, buf, sizeof buf, &len) == BK_OK && len == n);
    assert(strcmp(buf, want) == 0);
    assert(bk_read_string_utf8(ctx, v, mode, buf, n, &len) == BK_ERR_FULL && len == n);
}

static void expect_encoding_error(bk_value v) {
    char buf[64];
    size_t len = 0;
    assert(bk_read_string_utf8(ctx, v, BK_UTF8_STRICT, buf, sizeof buf, &len) == BK_ERR_ENCODING);
    assert(bk_get_error_code(ctx) == BK_ERR_ENCODING);
}

static int equals(bk_value v, const char *src) {
    bk_value expect = eval(src);
    bk_value same = eval("(function (a, b) { return a === b; })");
    bk_value args[2] = { v, expect };
    bk_value r = bk_call(ctx, same, 0, args, 2);
    int ok = 0;
    assert(r && bk_read_bool(ctx, r, &ok) == BK_OK);
    bk_free_value(ctx, r);
    bk_free_value(ctx, same);
    bk_free_value(ctx, expect);
    return ok;
}

int main(void) {
    ctx = bk_new_context(bk_new_runtime());
    assert(ctx);

    /* Empty string through every creator and reader. */
    {
        bk_value a = bk_new_string(ctx, "", 0);
        bk_value b = bk_new_string_latin1(ctx, NULL, 0);
        bk_value c = bk_new_string_utf16(ctx, NULL, 0);
        assert(a && b && c);
        expect_units(a, NULL, 0);
        expect_units(b, NULL, 0);
        expect_units(c, NULL, 0);
        expect_utf8(a, BK_UTF8_REPLACE, "");
        expect_utf8(c, BK_UTF8_STRICT, "");
        bk_free_value(ctx, a);
        bk_free_value(ctx, b);
        bk_free_value(ctx, c);
    }

    /* Latin-1: each byte is the code point of the same value. */
    {
        const uint8_t chars[] = { 'a', 0xE9, 0xFF, 0x80 };
        const uint16_t units[] = { 'a', 0xE9, 0xFF, 0x80 };
        bk_value v = bk_new_string_latin1(ctx, chars, sizeof chars);
        assert(v);
        expect_units(v, units, 4);
        expect_utf8(v, BK_UTF8_REPLACE, "a\xC3\xA9\xC3\xBF\xC2\x80");
        expect_utf8(v, BK_UTF8_STRICT, "a\xC3\xA9\xC3\xBF\xC2\x80");
        assert(equals(v, "'a\\u00e9\\u00ff\\u0080'"));
        bk_free_value(ctx, v);
    }

    /* Astral characters: UTF-8 in, a surrogate pair in UTF-16. */
    {
        const uint16_t units[] = { 0xD83D, 0xDE00, 'x' };
        bk_value from8 = bk_new_string(ctx, "\xF0\x9F\x98\x80x", 5);
        bk_value from16 = bk_new_string_utf16(ctx, units, 3);
        assert(from8 && from16);
        expect_units(from8, units, 3);
        expect_units(from16, units, 3);
        expect_utf8(from8, BK_UTF8_STRICT, "\xF0\x9F\x98\x80x");
        expect_utf8(from16, BK_UTF8_STRICT, "\xF0\x9F\x98\x80x");
        assert(equals(from8, "'\\u{1F600}x'"));
        assert(equals(from16, "'\\u{1F600}x'"));
        bk_free_value(ctx, from8);
        bk_free_value(ctx, from16);
    }

    /* Lone surrogates survive UTF-16, become U+FFFD or an error in UTF-8. */
    {
        const uint16_t high[] = { 'a', 0xD800, 'b' };
        const uint16_t low[] = { 0xDC00, 0xD800 };
        bk_value v = bk_new_string_utf16(ctx, high, 3);
        bk_value w = bk_new_string_utf16(ctx, low, 2);
        assert(v && w);
        expect_units(v, high, 3);
        expect_units(w, low, 2);
        expect_utf8(v, BK_UTF8_REPLACE, "a\xEF\xBF\xBD" "b");
        expect_utf8(w, BK_UTF8_REPLACE, "\xEF\xBF\xBD\xEF\xBF\xBD");
        expect_encoding_error(v);
        expect_encoding_error(w);
        char buf[64];
        size_t len = 0;
        assert(bk_read_string(ctx, v, buf, sizeof buf, &len) == BK_OK);
        assert(strcmp(buf, "a\xEF\xBF\xBD" "b") == 0);
        assert(equals(v, "'a\\ud800b'"));
        bk_free_value(ctx, v);
        bk_free_value(ctx, w);
    }

    /* A string built by script reads back the same through each reader. */
    {
        bk_value v = eval("'\\ud83d\\ude00\\u00e9\\u0041\\u20ac'");
        const uint16_t units[] = { 0xD83D, 0xDE00, 0xE9, 'A', 0x20AC };
        expect_units(v, units, 5);
        expect_utf8(v, BK_UTF8_STRICT, "\xF0\x9F\x98\x80\xC3\xA9" "A\xE2\x82\xAC");
        bk_free_value(ctx, v);
    }

    /* Invalid UTF-8 is rejected, not stored. */
    {
        static const char *bad[] = {
            "\xFF", "\xC0\x80", "\xED\xA0\x80", "\xF4\x90\x80\x80", "\xE2\x82", "\x80",
        };
        for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
            bk_value v = bk_new_string(ctx, bad[i], strlen(bad[i]));
            assert(v == 0);
            assert(bk_get_error_code(ctx) == BK_ERR_ENCODING);
        }
    }

    /* Wrong types and unknown modes. */
    {
        bk_value n = bk_new_number(ctx, 1);
        char buf[8];
        size_t len = 0;
        assert(bk_read_string_utf8(ctx, n, BK_UTF8_REPLACE, buf, sizeof buf, &len) == BK_ERR_TYPE);
        assert(bk_read_string_utf16(ctx, n, NULL, 0, &len) == BK_ERR_TYPE);
        assert(bk_string_length(ctx, n) == 0);
        bk_value s = bk_new_string(ctx, "x", 1);
        assert(bk_read_string_utf8(ctx, s, (bk_utf8_mode)7, buf, sizeof buf, &len) == BK_ERR_INVALID);
        bk_free_value(ctx, s);
        bk_free_value(ctx, n);
    }

    bk_free_context(ctx);
    puts("strings: PASS");
    return 0;
}
