/*
 * dtoa bindings: C3 interop with QuickJS dtoa.c through dtoa_wrapper.
 *
 * QuickJS' `js_atod` is a David-Gay-style decimal parser that matches
 * V8/SpiderMonkey, so `0.1 + 0.2` and `8.3 - 1` round-trip as in other engines.
 *
 * `js_atod` needs a scratch buffer (JSATODTempMem, 216 bytes). The C wrapper
 * takes a `void*` of BOOMKAT_DTOA_TMP_SIZE bytes, which C3 passes as a
 * fixed-size char array.
 */
module boomkat::dtoa_bindings;


const usz DTOA_TMP_SIZE = 216;
const usz DTOA_FORMAT_TMP_SIZE = 296;

/* JS_DTOA_* flags mirrored from quickjs/dtoa.h. */
const int JS_DTOA_FORMAT_FREE  = 0;
const int JS_DTOA_FORMAT_FIXED = 1;
const int JS_DTOA_FORMAT_FRAC  = 2;
const int JS_DTOA_EXP_ENABLED  = 4;

/*
 * Parse a number from `str` (need not be null-terminated).
 *
 *   str:   the C string to parse.
 *   pnext: out parameter, pointing on success at the first unconsumed char,
 *           on failure is set to `str`.
 *   radix: the base, where 0 auto-detects a 0x, 0o, or 0b prefix for ints.
 *   flags: the JS_DTOA_* bits above.
 *   tmp:   DTOA_TMP_SIZE bytes of scratch memory.
 *
 * Returns the parsed value (NaN on parse failure).
 */
extern fn double boomkat_js_atod(char* str, char** pnext, int radix, int flags,
                                 char[DTOA_TMP_SIZE]* tmp);

extern fn int boomkat_js_dtoa(char* buf, double d, int radix, int n_digits, int flags,
                              char[DTOA_FORMAT_TMP_SIZE]* tmp);

/*
 * strtod-compatible base-10 parser backed by js_atod, shared with the lexer.
 *
 * Parses a number at `str` and writes the first unconsumed char to `*endptr`.
 * On failure it leaves `*endptr == str`, as strtod does, and returns NaN.
 */
fn double atod_strtod_compat(char* str, char** endptr) {
    char[DTOA_TMP_SIZE] tmp;
    char* next = str;
    double v = boomkat_js_atod(str, &next, 10, 0, &tmp);
    *endptr = next;
    return v;
}