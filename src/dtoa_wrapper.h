/*
 * dtoa wrapper — simplified C API for QuickJS dtoa.c
 *
 * Provides a thin C3-friendly shim that hides the JSATODTempMem scratch
 * buffer (216 bytes on the stack). The engine calls into QuickJS' js_atod
 * so decimal literals and string-to-number conversion match V8/SpiderMonkey
 * instead of libc's strtod (e.g. "8.3 - 1 === 7.3" works, "0.1 + 0.2" is
 * stable across literal and parseFloat).
 *
 * The wrapper keeps the upstream dtoa.c unmodified — we just translate the
 * raw int flags that the lexer/builtins already use into JS_ATOD_* bits and
 * hide the per-call scratch struct.
 */
#ifndef DUKTAPE_DTOA_WRAPPER_H
#define DUKTAPE_DTOA_WRAPPER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Parse a number from a null-terminated C string.
 *
 *   str    — pointer into the input buffer (need not be null-terminated; we
 *            never read past *pnext on success).
 *   pnext  — out: pointer to the first character that was not consumed. On
 *            parse failure, *pnext == str.
 *   radix  — base. 0 means auto-detect from prefix (0x / 0o / 0b) for
 *            integers only. Use 10 for the lexer's plain-decimal path.
 *   flags  — JS_ATOD_* flags from QuickJS (see dtoa.h):
 *              JS_ATOD_INT_ONLY              — reject any '.' or exponent
 *              JS_ATOD_ACCEPT_BIN_OCT        — accept 0b / 0o prefixes
 *              JS_ATOD_ACCEPT_LEGACY_OCTAL   — accept 017 as legacy octal
 *              JS_ATOD_ACCEPT_UNDERSCORES    — accept '_' between digits
 *   tmp    — pointer to a JSATODTempMem-typed buffer (216 bytes); the caller
 *            supplies it (one per call is fine).
 *
 * Returns the parsed value. On failure returns NAN with *pnext == str.
 *
 * The exact scratch-buffer layout is private to dtoa.c; we treat it as
 * opaque memory here. The size is sizeof(JSATODTempMem) == 27 * 8 = 216.
 */
double duktape_js_atod(const char *str, const char **pnext, int radix, int flags,
                       void *tmp);

/*
 * Format a double using QuickJS' js_dtoa.
 *
 *   buf       — output buffer (must be large enough; use js_dtoa_max_len or
 *               a buffer of at least 256 bytes).
 *   d         — value to format.
 *   radix     — base (10 for JS number formatters).
 *   n_digits  — number of digits (meaning depends on flags).
 *   flags     — JS_DTOA_FORMAT_* and JS_DTOA_EXP_* bits.
 *   tmp       — scratch buffer of DUKTAPE_DTOA_FORMAT_TMP_SIZE bytes.
 *
 * Returns the length of the formatted string.
 */
int duktape_js_dtoa(char *buf, double d, int radix, int n_digits, int flags,
                    void *tmp);

/* Size, in bytes, of the scratch buffer expected by duktape_js_atod. */
#define DUKTAPE_DTOA_TMP_SIZE 216
/* Size, in bytes, of the scratch buffer expected by duktape_js_dtoa. */
#define DUKTAPE_DTOA_FORMAT_TMP_SIZE 296

#ifdef __cplusplus
}
#endif

#endif /* DUKTAPE_DTOA_WRAPPER_H */