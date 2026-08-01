/*
 * RegExp wrapper — implementation using QuickJS libregexp
 */
#include <stdlib.h>
#include <string.h>
#include "libregexp.h"
#include "re_wrapper.h"

/* User-provided callbacks for libregexp */
bool lre_check_stack_overflow(void *opaque, size_t alloca_size)
{
    (void)opaque; (void)alloca_size;
    return false;
}

int lre_check_timeout(void *opaque)
{
    (void)opaque;
    return 0;
}

void *lre_realloc(void *opaque, void *ptr, size_t size)
{
    (void)opaque;
    if (size == 0) { free(ptr); return NULL; }
    return realloc(ptr, size);
}

struct ReCompiled {
    uint8_t* bc;
    int      bc_len;
    int      capture_count;
    int      refcount;   /* shared compiled bytecode: freed when this hits 0 */
};

static uint8_t* cesu8_pattern_to_utf8(const char* input, size_t input_len, size_t* out_len);

ReCompiled* re_compile(const char* pattern, size_t pattern_len,
                       int flags, char* error_msg, int error_msg_size)
{
    int lre_flags = 0;
    if (flags & RE_FLAG_IGNORECASE)   lre_flags |= LRE_FLAG_IGNORECASE;
    if (flags & RE_FLAG_MULTILINE)    lre_flags |= LRE_FLAG_MULTILINE;
    if (flags & RE_FLAG_DOTALL)       lre_flags |= LRE_FLAG_DOTALL;
    if (flags & RE_FLAG_UNICODE)      lre_flags |= LRE_FLAG_UNICODE;
    if (flags & RE_FLAG_STICKY)       lre_flags |= LRE_FLAG_STICKY;
    if (flags & RE_FLAG_INDICES)      lre_flags |= LRE_FLAG_INDICES;
    if (flags & RE_FLAG_UNICODE_SETS) lre_flags |= LRE_FLAG_UNICODE_SETS;
    /* per ES2024: u and v are mutually exclusive */
    if ((lre_flags & LRE_FLAG_UNICODE) && (lre_flags & LRE_FLAG_UNICODE_SETS)) {
        if (error_msg && error_msg_size > 0) {
            strncpy(error_msg, "invalid regular expression flags", error_msg_size - 1);
            error_msg[error_msg_size - 1] = '\0';
        }
        return NULL;
    }

    /* lre_compile parses the pattern as standard UTF-8; our internal storage
     * is CESU-8 (each surrogate half is its own 3-byte sequence), so astral
     * literals in the pattern must be recombined into real 4-byte UTF-8
     * sequences before compiling, or the parser sees two lone surrogates
     * instead of one codepoint > 0xFFFF. Only do this in unicode mode
     * (u/v): lre_compile's non-unicode parser explicitly rejects codepoints
     * above 0xFFFF (patterns operate on UTF-16 code units, not codepoints,
     * when !is_unicode), so astral literals there must stay as two lone
     * surrogate code units. */
    int is_unicode_mode = (lre_flags & (LRE_FLAG_UNICODE | LRE_FLAG_UNICODE_SETS)) != 0;
    size_t utf8_len = 0;
    uint8_t* utf8_pattern = NULL;
    if (is_unicode_mode) {
        utf8_pattern = cesu8_pattern_to_utf8(pattern, pattern_len, &utf8_len);
        if (pattern_len > 0 && !utf8_pattern) {
            if (error_msg && error_msg_size > 0) {
                strncpy(error_msg, "out of memory", error_msg_size - 1);
                error_msg[error_msg_size - 1] = '\0';
            }
            return NULL;
        }
    }

    char internal_error[128];
    int bc_len;
    uint8_t* bc = lre_compile(&bc_len, internal_error, sizeof(internal_error),
                               (const char*)(utf8_pattern ? utf8_pattern : (const uint8_t*)pattern),
                               utf8_pattern ? utf8_len : pattern_len, lre_flags, NULL);
    free(utf8_pattern);
    if (!bc) {
        if (error_msg && error_msg_size > 0) {
            strncpy(error_msg, internal_error, error_msg_size - 1);
            error_msg[error_msg_size - 1] = '\0';
        }
        return NULL;
    }

    ReCompiled* re = (ReCompiled*)malloc(sizeof(ReCompiled));
    if (!re) { lre_realloc(NULL, bc, 0); return NULL; }

    re->bc = bc;
    re->bc_len = bc_len;
    re->capture_count = lre_get_capture_count(bc);
    re->refcount = 1;

    if (error_msg && error_msg_size > 0) error_msg[0] = '\0';
    return re;
}

/* Decode a single UTF-8 (CESU-8) byte sequence starting at p, advance *p past it. */
static uint32_t decode_utf8_unit(const uint8_t** p, const uint8_t* end)
{
    const uint8_t* s = *p;
    uint8_t c0 = s[0];
    if (c0 < 0x80) { *p = s + 1; return c0; }
    if ((c0 & 0xE0) == 0xC0 && s + 1 < end) {
        *p = s + 2;
        return ((c0 & 0x1F) << 6) | (s[1] & 0x3F);
    }
    if ((c0 & 0xF0) == 0xE0 && s + 2 < end) {
        *p = s + 3;
        return ((c0 & 0x0F) << 12) | ((s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    }
    /* invalid/truncated lead byte: treat as a single raw byte unit */
    *p = s + 1;
    return c0;
}

/*
 * Re-encode a CESU-8 buffer (each UTF-16 code unit independently encoded as
 * a standalone UTF-8 sequence) into standard UTF-8 for lre_compile(): every
 * adjacent high+low surrogate pair (each a lone 3-byte CESU-8 sequence) is
 * recombined into a single 4-byte UTF-8 sequence for the astral codepoint.
 * Lone/unpaired surrogates already look like valid 3-byte UTF-8 sequences
 * and pass through unchanged (lre_compile's UTF-8 decoder accepts them as
 * plain codepoints in the surrogate range, same as duktape/QuickJS do for
 * unicode-mode patterns). Returns a malloc'd, NUL-terminated buffer (caller
 * frees) holding at most `input_len` bytes of pattern data; writes the
 * output length (excluding the NUL) to *out_len. The trailing NUL is
 * required by lre_compile()'s UTF-8 decoder, which is documented (cutils.h)
 * to read up to UTF8_CHAR_LEN_MAX (4) bytes past the last consumed byte
 * unless the buffer is null-terminated — an exact-sized buffer without it
 * is a heap over-read whenever a multi-byte sequence starts near the end.
 */
static uint8_t* cesu8_pattern_to_utf8(const char* input, size_t input_len, size_t* out_len)
{
    uint8_t* out = (uint8_t*)malloc((input_len > 0 ? input_len : 0) + 1);
    if (!out) { *out_len = 0; return NULL; }

    const uint8_t* p = (const uint8_t*)input;
    const uint8_t* end = p + input_len;
    size_t o = 0;
    while (p < end) {
        const uint8_t* unit_start = p;
        uint32_t cp = decode_utf8_unit(&p, end);
        if (cp >= 0xD800 && cp <= 0xDBFF && p < end) {
            const uint8_t* p2 = p;
            uint32_t low = decode_utf8_unit(&p2, end);
            if (low >= 0xDC00 && low <= 0xDFFF) {
                uint32_t astral = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                out[o++] = (uint8_t)(0xF0 | (astral >> 18));
                out[o++] = (uint8_t)(0x80 | ((astral >> 12) & 0x3F));
                out[o++] = (uint8_t)(0x80 | ((astral >> 6) & 0x3F));
                out[o++] = (uint8_t)(0x80 | (astral & 0x3F));
                p = p2;
                continue;
            }
        }
        size_t unit_bytes = (size_t)(p - unit_start);
        memcpy(out + o, unit_start, unit_bytes);
        o += unit_bytes;
    }
    out[o] = 0;
    *out_len = o;
    return out;
}

/*
 * Convert a CESU-8 buffer (each UTF-16 code unit independently encoded as a
 * standalone UTF-8 sequence) into a flat uint16_t buffer, and record for each
 * emitted code unit the CESU-8 byte offset it started at (plus one trailing
 * entry for the end-of-buffer byte offset), so exec results can be mapped
 * back from code-unit offsets to CESU-8 byte offsets.
 */
static uint16_t* cesu8_to_utf16(const uint8_t* input, int input_len,
                                 int** out_byte_offsets, int* out_unit_count)
{
    uint16_t* units = (uint16_t*)malloc(sizeof(uint16_t) * (input_len + 1));
    int* offsets = (int*)malloc(sizeof(int) * (input_len + 1));
    if (!units || !offsets) { free(units); free(offsets); return NULL; }

    const uint8_t* p = input;
    const uint8_t* end = input + input_len;
    int n = 0;
    while (p < end) {
        offsets[n] = (int)(p - input);
        units[n] = (uint16_t)decode_utf8_unit(&p, end);
        n++;
    }
    offsets[n] = input_len;

    *out_byte_offsets = offsets;
    *out_unit_count = n;
    return units;
}

/* Map a code-unit offset (as returned by lre_exec in 16-bit modes) back to a
 * CESU-8 byte offset using the offsets table built by cesu8_to_utf16(). */
static int unit_offset_to_byte_offset(const int* byte_offsets, int unit_count, int unit_offset)
{
    if (unit_offset < 0) return -1;
    if (unit_offset > unit_count) unit_offset = unit_count;
    return byte_offsets[unit_offset];
}

int re_run(ReCompiled* re, const char* input, int input_len,
           int start_offset, int input_is_ascii,
           int* out_start, int* out_end, int* out_num_captures,
           int* caps_start, int* caps_end, int max_captures)
{
    if (!re || !re->bc) return RE_ERROR;

    int total_captures = re->capture_count;
    if (total_captures > RE_MAX_CAPTURES) total_captures = RE_MAX_CAPTURES;

    /* lre_exec NULL-initialises capture[0..2*capture_count-1] (it reads the
     * count from the compiled bytecode header) and writes back matching
     * pointers for the captures that participate in the match. A regex with
     * more than RE_MAX_CAPTURES capture groups would blow the 64-slot
     * stack array on every call, so we heap-allocate when the compiled
     * regex carries more captures than the stack buffer can hold. The
     * outer cap on `total_captures` (above) and the inner cap on the
     * copy-out loop (using max_captures) keep callers' caps_* arrays safe
     * even when lre_exec was passed a larger capture buffer. */
    uint8_t* capture_stack[RE_MAX_CAPTURES * 2];
    uint8_t** capture = capture_stack;
    if (re->capture_count > RE_MAX_CAPTURES) {
        capture = (uint8_t**)calloc((size_t)re->capture_count * 2, sizeof(uint8_t*));
        if (!capture) return RE_ERROR;
    }

    /* Fast path: pure-ASCII input. Each byte is exactly one UTF-16 code unit
     * (value < 0x80), so the raw bytes can be matched directly in 8-bit mode
     * (cbuf_type == 0) with no transcode and no allocation. Capture pointers
     * come back as byte pointers into `input`, and for ASCII the byte offset
     * equals both the code-unit offset and the CESU-8 offset, so no offset
     * remapping is needed. This is what QuickJS does for its 8-bit strings.
     * Note: unicode-mode (u/v) regexps are still correct here — surrogate
     * combining never applies to input that is entirely < 0x80. */
    if (input_is_ascii) {
        int ret = lre_exec(capture, re->bc,
                           (const uint8_t*)input, start_offset, input_len,
                           0 /* cbuf_type: 8-bit */, NULL);
        if (ret == RE_MATCH) {
            const uint8_t* base = (const uint8_t*)input;
            if (out_start) *out_start = capture[0] ? (int)(capture[0] - base) : -1;
            if (out_end)   *out_end   = capture[1] ? (int)(capture[1] - base) : -1;
            if (out_num_captures) *out_num_captures = total_captures - 1;
            for (int i = 1; i < total_captures && (i - 1) < max_captures; i++) {
                int idx = i * 2;
                caps_start[i - 1] = capture[idx]     ? (int)(capture[idx]     - base) : -1;
                caps_end[i - 1]   = capture[idx + 1] ? (int)(capture[idx + 1] - base) : -1;
            }
            if (capture != capture_stack) free(capture);
            return RE_MATCH;
        }
        if (capture != capture_stack) free(capture);
        if (ret == 0) return RE_NO_MATCH;
        return RE_ERROR;
    }

    /* lre_exec derives is_unicode from the compiled bytecode itself and
     * internally promotes cbuf_type 1->2 (surrogate-pair combining) when the
     * u/v flag is set; the buffer stride is always 2 bytes/unit regardless,
     * so we must always pass 1 here (passing 2 doubles cbuf_end's stride). */
    int cbuf_type = 1;

    uint16_t* units = NULL;
    int* byte_offsets = NULL;
    int unit_count = 0;
    int unit_start_offset = start_offset;

    units = cesu8_to_utf16((const uint8_t*)input, input_len, &byte_offsets, &unit_count);
    if (!units) return RE_ERROR;

    /* start_offset is a CESU-8 byte offset; find the matching unit index
     * (start_offset always lands exactly on a unit boundary in our storage). */
    for (int i = 0; i <= unit_count; i++) {
        if (byte_offsets[i] >= start_offset) { unit_start_offset = i; break; }
        unit_start_offset = i + 1;
    }

    int ret = lre_exec(capture, re->bc,
                       (const uint8_t*)units, unit_start_offset, unit_count,
                       cbuf_type, NULL);

    if (ret == RE_MATCH) {
        if (out_start) {
            int u = capture[0] ? (int)((const uint16_t*)capture[0] - units) : -1;
            *out_start = unit_offset_to_byte_offset(byte_offsets, unit_count, u);
        }
        if (out_end) {
            int u = capture[1] ? (int)((const uint16_t*)capture[1] - units) : -1;
            *out_end = unit_offset_to_byte_offset(byte_offsets, unit_count, u);
        }
        if (out_num_captures) *out_num_captures = total_captures - 1;

        for (int i = 1; i < total_captures && (i - 1) < max_captures; i++) {
            int idx = i * 2;
            int su = capture[idx] ? (int)((const uint16_t*)capture[idx] - units) : -1;
            int eu = capture[idx + 1] ? (int)((const uint16_t*)capture[idx + 1] - units) : -1;
            caps_start[i - 1] = unit_offset_to_byte_offset(byte_offsets, unit_count, su);
            caps_end[i - 1] = unit_offset_to_byte_offset(byte_offsets, unit_count, eu);
        }
        free(units);
        free(byte_offsets);
        if (capture != capture_stack) free(capture);
        return RE_MATCH;
    }

    free(units);
    free(byte_offsets);
    if (capture != capture_stack) free(capture);

    if (ret == 0) return RE_NO_MATCH;
    return RE_ERROR;
}

void re_free(ReCompiled* re)
{
    if (re) {
        if (--re->refcount > 0) return;  /* still borrowed elsewhere */
        if (re->bc) lre_realloc(NULL, re->bc, 0);
        free(re);
    }
}

/* Take an additional reference to a shared compiled regexp. */
void re_ref(ReCompiled* re)
{
    if (re) re->refcount++;
}

const char* re_get_groupnames(ReCompiled* re)
{
    if (!re || !re->bc) return NULL;
    return lre_get_groupnames(re->bc);
}

int re_get_capture_count(ReCompiled* re)
{
    if (!re || !re->bc) return 0;
    return re->capture_count;
}
