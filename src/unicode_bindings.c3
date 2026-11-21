/*
 * Unicode normalization C bindings: C3 interop with QuickJS libunicode
 * through unicode_wrapper.
 */
module boomkat::unicode_bindings;

alias UnicodeReallocFn = fn void*(void* opaque, void* ptr, usz size);

/*
 * Normalize a string of uint32_t codepoints into memory from `realloc_fn`,
 * which libunicode grows as the decomposition expands. Returns NULL on
 * failure; sets *out_len to the number of codepoints.
 */
extern fn uint* unicode_normalize_with(uint* src, int src_len, int n_type, int* out_len,
                                       void* opaque, UnicodeReallocFn realloc_fn);

faultdef NORMALIZE_FAILED;

// libunicode's output buffer. It grows the buffer by 1.5x from the source
// length; the first allocation takes twice that, so ordinary decompositions
// never reallocate. A chain of large reallocs leaves the abandoned blocks
// resident in some allocators (macOS caches them), growing the footprint on
// every call.
struct NormalizeBuffer @local {
    Allocator alloc;
    void* block;
    usz cap;
}

fn void* normalize_buffer_realloc(void* opaque, void* ptr, usz size) @local {
    NormalizeBuffer* buf = opaque;
    if (size == 0) {
        if (ptr != null) alloc::free(buf.alloc, ptr);
        if (ptr == buf.block) buf.block = null;
        return null;
    }
    if (ptr != null && ptr == buf.block && size <= buf.cap) return ptr;
    usz cap = ptr == null ? size * 2 : size;
    void* grown = ptr == null ? alloc::malloc_try(buf.alloc, (sz)cap) ?? null
                              : alloc::realloc_try(buf.alloc, ptr, (sz)cap) ?? null;
    if (grown == null) return null;
    buf.block = grown;
    buf.cap = cap;
    return grown;
}

// The `n_type` normalization of `src`, allocated with `a`. The caller frees it
// through `a`.
fn uint[]? normalize(Allocator a, uint[] src, int n_type) {
    NormalizeBuffer buf = { .alloc = a };
    int len;
    uint* out = unicode_normalize_with(src.ptr, (int)src.len, n_type, &len, &buf, &normalize_buffer_realloc);
    if (out == null || len < 0) return NORMALIZE_FAILED~;
    return out[:len];
}

/*
 * Identifier classification from libregexp's vendored ID_Start and ID_Continue
 * tables. Includes Other_ID_Start / Other_ID_Continue and ZWNJ/ZWJ
 * (U+200C/U+200D) on the continue side.
 *
 * Returns 1 for a valid identifier start / continue character, 0 otherwise.
 * ASCII takes a fast path; >= 128 uses the full Unicode table.
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
 * Returns the number of mapped codepoints, 1 to 3.
 */
extern fn int unicode_case_conv(uint cp, int conv_type, uint* out);

/* Unicode Cased / Case_Ignorable properties (needed for Final_Sigma). */
extern fn int unicode_is_cased(uint cp);
extern fn int unicode_is_case_ignorable(uint cp);

/* Canonical_Combining_Class of a code point, 0 to 254. */
extern fn int unicode_combining_class(uint cp);

/* Soft_Dotted property; builds the range set per call, so for rare lookups. */
extern fn int unicode_is_soft_dotted(uint cp);

/* Normalization form constants (matching libunicode.h) */
const int UNICODE_NFC  = 0;
const int UNICODE_NFD  = 1;
const int UNICODE_NFKC = 2;
const int UNICODE_NFKD = 3;
