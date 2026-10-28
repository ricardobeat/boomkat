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


static int is_wide_pattern(const bk_string_view *view, const uint16_t *want, size_t n) {
    return view->width == 2 && view->length == n && memcmp(view->data, want, n * sizeof *want) == 0;
}

/* Strings expose their stored units: Latin-1 bytes when every unit is at most
 * 0xFF, native UTF-16 otherwise. */
static void string_views(void) {
    bk_string_view view;

    bk_value ascii = bk_new_string(ctx, "hello", 5);
    assert(bk_string_view_get(ctx, ascii, &view) == BK_OK);
    assert(view.width == 1 && view.ascii && view.length == 5 && memcmp(view.data, "hello", 5) == 0);

    bk_value latin = bk_new_string(ctx, "caf\xC3\xA9", 5);
    assert(bk_string_view_get(ctx, latin, &view) == BK_OK);
    assert(view.width == 1 && !view.ascii && view.length == 4);
    assert(memcmp(view.data, "caf\xE9", 4) == 0);

    const uint16_t wide[] = { 'a', 0x20AC, 0xD800 };
    bk_value w = bk_new_string_utf16(ctx, wide, 3);
    assert(bk_string_view_get(ctx, w, &view) == BK_OK);
    assert(is_wide_pattern(&view, wide, 3) && !view.ascii);

    /* A UTF-16 buffer of Latin-1 units is stored narrow. */
    const uint16_t narrow[] = { 'a', 0xE9 };
    bk_value n = bk_new_string_utf16(ctx, narrow, 2);
    assert(bk_string_view_get(ctx, n, &view) == BK_OK);
    assert(view.width == 1 && !view.ascii && view.length == 2);

    bk_value empty = bk_new_string(ctx, "", 0);
    assert(bk_string_view_get(ctx, empty, &view) == BK_OK && view.length == 0 && view.width == 1);

    bk_value number = bk_new_number(ctx, 1);
    assert(bk_string_view_get(ctx, number, &view) == BK_ERR_TYPE);
    assert(bk_string_view_get(ctx, ascii, NULL) == BK_ERR_INVALID);

    /* A view taken before a collection is gone; a fresh one reads the same units. */
    bk_value junk = eval("(function () { var s = 0; for (var i = 0; i < 20000; i++) s += ('x' + i + '\\u20ac').length; return s; })()");
    bk_free_value(ctx, junk);
    assert(bk_string_view_get(ctx, w, &view) == BK_OK && is_wide_pattern(&view, wide, 3));

    bk_free_value(ctx, number);
    bk_free_value(ctx, empty);
    bk_free_value(ctx, n);
    bk_free_value(ctx, w);
    bk_free_value(ctx, latin);
    bk_free_value(ctx, ascii);
}

static int releases;
static const void *released_data;
static size_t released_length;
static void *released_opaque;

static void on_release(void *opaque, const void *data, size_t length) {
    releases++;
    released_opaque = opaque;
    released_data = data;
    released_length = length;
}

static void collect(void) {
    bk_value r = eval("(function () { for (var i = 0; i < 200000; i++) { var s = 'g' + i; } return 0; })()");
    bk_free_value(ctx, r);
}

/* External strings are read in place and released exactly once, when the
 * string is freed. */
static void external_strings(void) {
    static const uint8_t latin1[] = { 'c', 'a', 'f', 0xE9, '!' };
    static uint16_t wide[] = { 0x20AC, 'x', 0xD83D, 0xDE00 };
    static int marker;
    bk_string_view view;
    releases = 0;

    bk_value a = bk_new_external_string_latin1(ctx, latin1, 5, on_release, &marker);
    assert(a);
    assert(bk_string_view_get(ctx, a, &view) == BK_OK);
    assert(view.data == latin1 && view.width == 1 && view.length == 5 && !view.ascii);
    assert(equals(a, "'caf\\u00e9!'"));
    assert(releases == 0);

    bk_value b = bk_new_external_string_utf16(ctx, wide, 4, on_release, &marker);
    assert(b);
    assert(bk_string_view_get(ctx, b, &view) == BK_OK && view.data == wide && view.width == 2);
    assert(equals(b, "'\\u20acx\\ud83d\\ude00'"));
    expect_units(b, wide, 4);

    /* Used as a key, concatenated and sliced, the string behaves like any other. */
    bk_value keyed = eval("(function (s) { var o = {}; o[s] = 1; return (s + 'y').length === s.length + 1 && s.slice(1) === 'x\\ud83d\\ude00' && ('\\u20acx\\ud83d\\ude00' in o); })");
    bk_value r = bk_call(ctx, keyed, 0, &b, 1);
    int ok = 0;
    assert(r && bk_read_bool(ctx, r, &ok) == BK_OK && ok);
    bk_free_value(ctx, r);
    bk_free_value(ctx, keyed);

    bk_free_value(ctx, a);
    bk_free_value(ctx, b);
    collect();
    assert(releases == 2);

    /* Content with no external form is copied and released at once. */
    releases = 0;
    static const uint16_t narrow[] = { 'a', 0xE9 };
    bk_value c = bk_new_external_string_utf16(ctx, narrow, 2, on_release, &marker);
    assert(c && releases == 1 && released_data == narrow && released_length == 2 && released_opaque == &marker);
    assert(bk_string_view_get(ctx, c, &view) == BK_OK && view.data != narrow && view.width == 1);
    bk_value e = bk_new_external_string_latin1(ctx, latin1, 0, on_release, &marker);
    assert(e && releases == 2);
    assert(bk_string_length(ctx, e) == 0);
    bk_free_value(ctx, c);
    bk_free_value(ctx, e);

    /* A NULL release is allowed. */
    bk_value f = bk_new_external_string_latin1(ctx, latin1, 5, NULL, NULL);
    assert(f && bk_string_length(ctx, f) == 5);
    bk_free_value(ctx, f);

    assert(bk_new_external_string_latin1(ctx, NULL, 3, on_release, &marker) == BK_EXCEPTION);
    assert(releases == 2);

}

/* A string still alive when its runtime goes away is released with it. */
static void external_string_outlives_runtime(void) {
    static uint16_t wide[] = { 0x20AC, 'x' };
    static int marker;
    releases = 0;
    bk_ctx own = bk_create();
    assert(own);
    bk_value g = bk_new_external_string_utf16(own, wide, 2, on_release, &marker);
    assert(g && releases == 0);
    bk_destroy(own);
    assert(releases == 1 && released_data == wide && released_length == 2);
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

    string_views();
    external_strings();
    external_string_outlives_runtime();

    bk_free_context(ctx);
    puts("strings: PASS");
    return 0;
}
