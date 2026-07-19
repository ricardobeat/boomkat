/*
 * dtoa bindings — C3 interop with QuickJS dtoa.c via dtoa_wrapper.
 *
 * QuickJS' `js_atod` is a David-Gay-style decimal parser that matches
 * V8/SpiderMonkey, so literals like `0.1 + 0.2` and `8.3 - 1` round-trip
 * the way other engines do.  We use it everywhere libc::strtod was called.
 *
 * `js_atod` requires a scratch buffer (JSATODTempMem, 216 bytes); the C
 * wrapper hides that and accepts a `void*` of DUKTAPE_DTOA_TMP_SIZE bytes,
 * which C3 passes as a fixed-size char array.
 */
module duktape::dtoa_bindings;

/* js_atod accepts these flags (see quickjs/dtoa.h for full set). */
const int JS_ATOD_INT_ONLY             = (1 << 0);
const int JS_ATOD_ACCEPT_BIN_OCT       = (1 << 1);
const int JS_ATOD_ACCEPT_LEGACY_OCTAL  = (1 << 2);
const int JS_ATOD_ACCEPT_UNDERSCORES   = (1 << 3);

/* Size in bytes of the scratch buffer expected by duktape_js_atod. */
const usz DTOA_TMP_SIZE = 216;
/* Size in bytes of the scratch buffer expected by duktape_js_dtoa. */
const usz DTOA_FORMAT_TMP_SIZE = 296;

/* JS_DTOA_* flags mirrored from quickjs/dtoa.h. */
const int JS_DTOA_FORMAT_FREE  = 0;
const int JS_DTOA_FORMAT_FIXED = 1;
const int JS_DTOA_FORMAT_FRAC  = 2;
const int JS_DTOA_EXP_AUTO     = 0;
const int JS_DTOA_EXP_ENABLED  = 4;
const int JS_DTOA_EXP_DISABLED = 8;
const int JS_DTOA_MINUS_ZERO   = 16;

/*
 * Parse a number from `str` (need not be null-terminated).
 *
 *   str   — C string to parse.
 *   pnext — out parameter; on success points to the first unconsumed char,
 *           on failure is set to `str`.
 *   radix — base; 0 means auto-detect prefix (0x/0o/0b) for ints.
 *   flags — JS_ATOD_* bits above.
 *   tmp   — pointer to DTOA_TMP_SIZE bytes of scratch memory.
 *
 * Returns the parsed value (NaN on parse failure).
 */
extern fn double duktape_js_atod(char* str, char** pnext, int radix, int flags,
                                 char[DTOA_TMP_SIZE]* tmp);

extern fn int duktape_js_dtoa(char* buf, double d, int radix, int n_digits, int flags,
                              char[DTOA_FORMAT_TMP_SIZE]* tmp);

/*
 * strtod-compatible decimal parser backed by js_atod.
 *
 * Presents the classic (str, &endptr) -> double interface so it can drop into
 * the ToNumber / JSON number paths that previously called libc::strtod: parses
 * a base-10 number at `str`, writes the first unconsumed char to `*endptr`, and
 * on parse failure leaves `*endptr == str` (matching strtod's "nothing
 * consumed" signal) and returns NaN.  Uses the same David-Gay parser as the
 * lexer, so decimal rounding is spec-accurate and consistent engine-wide.
 */
fn double atod_strtod_compat(char* str, char** endptr) {
    char[DTOA_TMP_SIZE] tmp;
    char* next = str;
    double v = duktape_js_atod(str, &next, 10, 0, &tmp);
    *endptr = next;
    return v;
}