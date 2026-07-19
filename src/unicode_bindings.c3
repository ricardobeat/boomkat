/*
 * Unicode normalization C bindings — C3 interop with QuickJS libunicode via unicode_wrapper
 */
module duktape::unicode_bindings;

/*
 * Normalize a string of uint32_t codepoints.
 * Returns a uint32_t array malloc'd by the C wrapper. The caller frees it
 * with mem::free, which is compatible only while `mem` is the libc-backed
 * default allocator (C malloc / libc free must pair).
 * Returns NULL on failure. Sets *out_len to the number of codepoints.
 */
extern fn uint* unicode_normalize_simple(uint* src, int src_len,
                                          int n_type, int* out_len);

/*
 * Identifier classification — backed by libregexp's vendored ID_Start /
 * ID_Continue tables (matches the spec's IdentifierStart / IdentifierPart
 * property, including grandfathered Other_ID_Start / Other_ID_Continue
 * characters and ZWNJ/ZWJ (U+200C/U+200D) for the "continue" side).
 *
 * Returns 1 if the codepoint is a valid identifier start / continue
 * character, 0 otherwise. Fast ASCII path; >= 128 goes through the
 * full Unicode table.
 */
extern fn int unicode_is_identifier_start(uint cp);
extern fn int unicode_is_identifier_continue(uint cp);

/*
 * Unicode case conversion.
 *
 *   cp        - input codepoint
 *   conv_type - 0 = uppercase, 1 = lowercase
 *   out       - caller-provided uint[3] output buffer for mapped codepoints
 *
 * Returns the number of mapped codepoints (1–3).
 */
extern fn int unicode_case_conv(uint cp, int conv_type, uint* out);

/* Unicode Cased / Case_Ignorable properties (needed for Final_Sigma). */
extern fn int unicode_is_cased(uint cp);
extern fn int unicode_is_case_ignorable(uint cp);

/* Normalization form constants (matching libunicode.h) */
const int UNICODE_NFC  = 0;
const int UNICODE_NFD  = 1;
const int UNICODE_NFKC = 2;
const int UNICODE_NFKD = 3;
