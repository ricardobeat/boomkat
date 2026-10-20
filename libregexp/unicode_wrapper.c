/*
 * Unicode normalization wrapper — implementation using QuickJS libunicode
 */
#include <stdlib.h>
#include <string.h>
#include "libunicode.h"
#include "unicode_wrapper.h"
#include "cutils.h"

/* Default realloc callback for libunicode's DynBuf */
static void *default_realloc(void *opaque, void *ptr, size_t size)
{
    (void)opaque;
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    return realloc(ptr, size);
}

uint32_t* unicode_normalize_simple(const uint32_t* src, int src_len,
                                    int n_type, int* out_len)
{
    uint32_t *result = NULL;
    int len;

    if (out_len) *out_len = -1;

    len = unicode_normalize(&result, src, src_len,
                            (UnicodeNormalizationEnum)n_type,
                            NULL, default_realloc);

    if (len < 0) {
        /* On failure, unicode_normalize sets *pdst to NULL */
        if (out_len) *out_len = -1;
        return NULL;
    }

    if (out_len) *out_len = len;
    return result;
}

/*
 * Identifier classification — passthrough to libregexp's vendored
 * ID_Start / ID_Continue tables.
 *
 * The 8-bit fast path mirrors lre_js_is_ident_first / lre_js_is_ident_next
 * in quickjs (lre_ctype_bits table): [A-Z], [a-z], _, $, plus digits for
 * "continue". Everything >= 128 goes through the full Unicode property
 * table (lre_is_id_start / lre_is_id_continue).
 */
int unicode_is_identifier_start(uint32_t cp)
{
    if (cp < 128) {
        /* ASCII fast path — matches is_id_start_byte() in libunicode.h */
        return (cp >= 'A' && cp <= 'Z') ||
               (cp >= 'a' && cp <= 'z') ||
               cp == '_' || cp == '$';
    }
    return lre_is_id_start(cp);
}

int unicode_is_identifier_continue(uint32_t cp)
{
    if (cp < 128) {
        /* ASCII fast path — matches is_id_continue_byte() in libunicode.h */
        return (cp >= 'A' && cp <= 'Z') ||
               (cp >= 'a' && cp <= 'z') ||
               (cp >= '0' && cp <= '9') ||
               cp == '_' || cp == '$';
    }
    /* ZWNJ (U+200C) and ZWJ (U+200D) are accepted in identifier parts per
     * spec (UAX #31); lre_is_id_continue does not include them, so add them
     * here to mirror lre_js_is_ident_next from quickjs. */
    if (cp == 0x200C || cp == 0x200D) return 1;
    return lre_is_id_continue(cp);
}

/*
 * Unicode case conversion.
 *
 * Thin wrapper over lre_case_conv:
 *   conv_type = 0 → uppercase, 1 → lowercase (matches lre_case_conv convention)
 *
 * Returns the number of output codepoints (1–3).  `out` must point to a
 * uint32_t[3] buffer provided by the caller.
 */
int unicode_case_conv(uint32_t cp, int conv_type, uint32_t out[3])
{
    int n = lre_case_conv(out, cp, conv_type);
    return n;
}

int unicode_is_cased(uint32_t cp)
{
    return lre_is_cased(cp);
}

int unicode_is_case_ignorable(uint32_t cp)
{
    return lre_is_case_ignorable(cp);
}

int unicode_combining_class(uint32_t cp)
{
    return lre_get_combining_class(cp);
}
