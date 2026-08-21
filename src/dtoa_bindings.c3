/*
 * dtoa bindings: C3 interop with QuickJS dtoa.c through dtoa_wrapper.
 *
 * QuickJS' `js_atod` is a David-Gay-style decimal parser that matches
 * V8/SpiderMonkey, so literals like `0.1 + 0.2` and `8.3 - 1` round-trip
 * the way other engines do.  We use it everywhere libc::strtod was called.
 *
 * `js_atod` requires a scratch buffer (JSATODTempMem, 216 bytes); the C
 * wrapper hides that and accepts a `void*` of BOOMKAT_DTOA_TMP_SIZE bytes,
 * which C3 passes as a fixed-size char array.
 */
module boomkat::dtoa_bindings;


/* Size in bytes of the scratch buffer expected by boomkat_js_atod. */
const usz DTOA_TMP_SIZE = 216;
/* Size in bytes of the scratch buffer expected by boomkat_js_dtoa. */
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
 * strtod-compatible decimal parser backed by js_atod.
 *
 * Presents the classic (str, &endptr) -> double interface so it can drop into
 * the ToNumber / JSON number paths that call libc::strtod: parses
 * a base-10 number at `str`, writes the first unconsumed char to `*endptr`, and
 * on parse failure leaves `*endptr == str` (matching strtod's "nothing
 * consumed" signal) and returns NaN.  Uses the same David-Gay parser as the
 * lexer, so decimal rounding is spec-accurate and consistent engine-wide.
 */
fn double atod_strtod_compat(char* str, char** endptr) {
    char[DTOA_TMP_SIZE] tmp;
    char* next = str;
    double v = boomkat_js_atod(str, &next, 10, 0, &tmp);
    *endptr = next;
    return v;
}