/*
 * Unicode normalization wrapper — simplified C API for libunicode
 *
 * Provides a simple non-intrusive function for C3 interop.
 */
#ifndef UNICODE_WRAPPER_H
#define UNICODE_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Normalize a string of uint32_t codepoints.
 *
 * Parameters:
 *   src     - input codepoint array (not modified)
 *   src_len - number of codepoints in src
 *   n_type  - normalization form: 0=NFC, 1=NFD, 2=NFKC, 3=NFKD
 *   out_len - on success, set to the number of codepoints in the result
 *
 * Returns a newly malloc'd uint32_t array (caller must free with free()).
 * Returns NULL on failure (e.g. out of memory).
 */
uint32_t* unicode_normalize_simple(const uint32_t* src, int src_len,
                                   int n_type, int* out_len);

/*
 * Identifier character classification (per Unicode ID_Start / ID_Continue).
 *
 * Backed by libregexp's vendored ID_Start / ID_Continue property tables
 * (libunicode.c), which match the ECMAScript spec's IdentifierStart /
 * IdentifierPart character classes (incl. Other_ID_Start grandfathered
 * characters from Unicode 4.0–9.0 and ID_Continue-only grandfathered
 * characters from Unicode 4.1–6.0). These are the same tables QuickJS
 * uses for lre_js_is_ident_first / lre_js_is_ident_next.
 *
 * Returns 1 if the codepoint is a valid identifier start / continue
 * character, 0 otherwise. ASCII path is fast (table lookup); >127 goes
 * through the full Unicode table.
 */
int unicode_is_identifier_start(uint32_t cp);
int unicode_is_identifier_continue(uint32_t cp);

/*
 * Unicode case conversion via lre_case_conv.
 *
 *   cp        - input codepoint
 *   conv_type - 0 = uppercase, 1 = lowercase
 *   out       - output buffer for up to 3 mapped codepoints (caller provides)
 *
 * Returns the number of mapped codepoints (1–3).
 */
int unicode_case_conv(uint32_t cp, int conv_type, uint32_t out[3]);

/* Unicode Cased / Case_Ignorable properties — needed for Final_Sigma. */
int unicode_is_cased(uint32_t cp);
int unicode_is_case_ignorable(uint32_t cp);

/* Canonical_Combining_Class of a code point, 0 to 254. */
int unicode_combining_class(uint32_t cp);

/* Soft_Dotted property, for the Lithuanian casing rules. Builds the property's
 * range set on each call, so it suits rare lookups only. */
int unicode_is_soft_dotted(uint32_t cp);

#ifdef __cplusplus
}
#endif

#endif /* UNICODE_WRAPPER_H */
