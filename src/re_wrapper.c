/*
 * RegExp wrapper — implementation using QuickJS libregexp
 */
#define _GNU_SOURCE /* memmem on glibc */
#include <stdlib.h>
#include <string.h>
#include "libregexp.h"
#include "libunicode.h"
#include "re_wrapper.h"

/* User-provided callbacks for libregexp */
bool lre_check_stack_overflow(void *opaque, size_t alloca_size)
{
    (void)opaque; (void)alloca_size;
    return false;
}

int lre_check_timeout(void *opaque)
{
    ReInterrupt* interrupt = opaque;
    return interrupt && interrupt->poll ? interrupt->poll(interrupt->opaque) : 0;
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
    /* Every match starts with these literal ASCII bytes. With `anchored` the
     * match can only start at offset 0 (a leading `^` without the m flag), so
     * re_run rejects an input that cannot match without entering lre_exec. */
    int      anchored;
    int      prefix_len;
    char     prefix[16];
    /* the whole pattern is the prefix: a found prefix is the match */
    int      literal_only;
    int      prefix_rare;   /* index of the prefix byte to search for */
    int      required_len;
    int      required_rare;
    char     required[16];
    /* Code units that can begin a match, when has_first_set. */
    int      has_first_set;
    LREFirstSet first_set;
};

/* Rough frequency of an ASCII byte in typical text, used to pick the byte
 * a literal search scans for. */
static int re_byte_commonness(unsigned char c)
{
    if (c == ' ') return 100;
    if (strchr("etaoinsrhl\",:.", c)) return 80;
    if (c >= 'a' && c <= 'z') return 50;
    if (c >= '0' && c <= '9') return 45;
    if (c >= 'A' && c <= 'Z') return 30;
    if (strchr("/=_-()", c)) return 25;
    return 15;
}

static int re_pick_rare(const char* lit, int n)
{
    int best = 0;
    for (int i = 1; i < n; i++) {
        if (re_byte_commonness((unsigned char)lit[i]) < re_byte_commonness((unsigned char)lit[best]))
            best = i;
    }
    return best;
}

/* The first occurrence of `lit` in `len` bytes, found by scanning for its
 * byte at index `rare` and comparing the rest. */
static const char* re_find_lit8(const char* input, size_t len,
                                const char* lit, size_t n, size_t rare)
{
    if (len < n) return NULL;
    const char* p = input + rare;
    const char* last = input + (len - n) + rare;
    while (p <= last) {
        const char* hit = memchr(p, (unsigned char)lit[rare], (size_t)(last - p) + 1);
        if (!hit) return NULL;
        if (memcmp(hit - rare, lit, n) == 0) return hit - rare;
        p = hit + 1;
    }
    return NULL;
}

/* The first unit equal to `u` in [p, end), or NULL. */
static const uint16_t* re_find_unit16(const uint16_t* p, const uint16_t* end, uint16_t u)
{
#if (defined(__GNUC__) || defined(__clang__)) && defined(__BYTE_ORDER__) && \
    __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    const uint64_t ones = 0x0001000100010001ULL;
    const uint64_t pat = ones * u;
    while (end - p >= 4) {
        uint64_t w;
        memcpy(&w, p, sizeof(w));
        w ^= pat;
        /* the lowest flagged lane is the first unit equal to u */
        uint64_t z = (w - ones) & ~w & 0x8000800080008000ULL;
        if (z) return p + (__builtin_ctzll(z) >> 4);
        p += 4;
    }
#endif
    for (; p < end; p++) {
        if (*p == u) return p;
    }
    return NULL;
}

/* The first occurrence of the ASCII `lit` in `len` 16-bit units, or NULL. */
static const uint16_t* re_find_lit16(const uint16_t* input, size_t len,
                                     const char* lit, size_t n, size_t rare)
{
    if (len < n) return NULL;
    const uint16_t* p = input + rare;
    const uint16_t* end = input + (len - n) + rare + 1;
    while (p < end) {
        const uint16_t* hit = re_find_unit16(p, end, (unsigned char)lit[rare]);
        if (!hit) return NULL;
        const uint16_t* cand = hit - rare;
        size_t k = 0;
        while (k < n && cand[k] == (unsigned char)lit[k]) k++;
        if (k == n) return cand;
        p = hit + 1;
    }
    return NULL;
}

/* The unit offset of the first occurrence of `lit` at or after `start`, or -1. */
static long re_find_lit(const void* input, int input_wide, int start, int input_len,
                        const char* lit, int n, int rare)
{
    size_t rest = (size_t)(input_len - start);
    if (input_wide) {
        const uint16_t* base = (const uint16_t*)input;
        const uint16_t* hit = re_find_lit16(base + start, rest, lit, (size_t)n, (size_t)rare);
        return hit ? (long)(hit - base) : -1;
    }
    const char* base = (const char*)input;
    const char* hit = re_find_lit8(base + start, rest, lit, (size_t)n, (size_t)rare);
    return hit ? (long)(hit - base) : -1;
}

/* Records the literal prefix every match of `pattern` must start with. Any
 * alternation or the i flag disables it; a literal followed by a quantifier is
 * not part of the prefix. */
static void re_scan_prefix(ReCompiled* re, const char* pattern, size_t len, int lre_flags)
{
    re->anchored = 0;
    re->prefix_len = 0;
    if (lre_flags & LRE_FLAG_IGNORECASE) return;
    if (memchr(pattern, '|', len)) return;
    size_t i = 0;
    if (len > 0 && pattern[0] == '^') {
        re->anchored = !(lre_flags & LRE_FLAG_MULTILINE);
        i = 1;
    }
    int n = 0;
    for (; i < len && n < (int)sizeof(re->prefix); i++) {
        unsigned char c = (unsigned char)pattern[i];
        if (c >= 0x80 || c < 0x20 || strchr("\\^$.|?*+()[]{}", c)) break;
        re->prefix[n++] = (char)c;
    }
    /* a multiline `^` is an assertion the prefix does not cover */
    re->literal_only = i == len && n > 0 && (pattern[0] != '^' || re->anchored);
    if (i < len && n > 0 && strchr("?*+{", pattern[i])) n--;
    re->prefix_len = n;
    re->prefix_rare = re_pick_rare(re->prefix, n);
    if (n == 0) re->anchored = 0;
}

/* Find a mandatory ASCII substring outside groups, classes and top-level
 * alternatives. This is only a rejection filter: unlike a prefix, the bytes
 * may occur after the actual match start, so they must never advance it.
 * Declining an unfamiliar escape or quantified brace keeps this analysis
 * conservative as regexp syntax evolves. */
static void re_scan_required(ReCompiled* re, const char* pattern, size_t len, int flags)
{
    re->required_len = 0;
    re->required_rare = 0;
    if (re->prefix_len || (flags & (LRE_FLAG_IGNORECASE | LRE_FLAG_UNICODE_SETS))) return;
    char run[sizeof(re->required)], best[sizeof(re->required)];
    size_t run_len = 0, best_len = 0;
    int depth = 0, in_class = 0;
#define KEEP_RUN() do { \
    size_t n = run_len < sizeof(run) ? run_len : sizeof(run); \
    if (n > best_len) { memcpy(best, run, n); best_len = n; } \
    run_len = 0; \
} while (0)
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)pattern[i];
        if (c == '\\') {
            if (++i == len) return;
            c = (unsigned char)pattern[i];
            if (depth || in_class) continue;
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
                /* These assertions and classes consume no literal bytes. */
                if (c == 'b' || c == 'B' || c == 'd' || c == 'D' ||
                    c == 's' || c == 'S' || c == 'w' || c == 'W') {
                    KEEP_RUN();
                    continue;
                }
                return;
            }
            if (c < 0x20 || c >= 0x7f) return;
        } else {
            if (in_class) { if (c == ']') in_class = 0; continue; }
            if (c == '[') { if (!depth) KEEP_RUN(); in_class = 1; continue; }
            if (c == '(') { if (!depth) KEEP_RUN(); depth++; continue; }
            if (c == ')') { if (--depth < 0) return; continue; }
            if (depth) continue;
            if (c == '|' || c == '{') return;
            if (c == '?' || c == '*' || c == '+') {
                /* Conservatively drop even the one-or-more case. */
                if (run_len) run_len--;
                KEEP_RUN();
                continue;
            }
            if (c == '.' || c == '^' || c == '$' || c == ']' ||
                c < 0x20 || c >= 0x7f) { KEEP_RUN(); continue; }
        }
        if (run_len < sizeof(run)) run[run_len] = (char)c;
        run_len++;
    }
    if (depth || in_class) return;
    KEEP_RUN();
#undef KEEP_RUN
    /* Tiny searches cost more than they save on ordinary short inputs. */
    if (best_len >= 3) {
        memcpy(re->required, best, best_len);
        re->required_len = (int)best_len;
        re->required_rare = re_pick_rare(re->required, (int)best_len);
    }
}

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

    /* lre_compile parses the pattern as standard UTF-8; the pattern arrives as
     * CESU-8 text (each surrogate half is its own 3-byte sequence), so astral
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
    re_scan_prefix(re, pattern, pattern_len, lre_flags);
    re_scan_required(re, pattern, pattern_len, lre_flags);
    re->has_first_set = lre_get_first_set(bc, &re->first_set);

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
 * Run `re` over `input_len` code units of `input`, starting at unit
 * `start_offset`. The input is Latin-1 bytes, or native-endian UTF-16 when
 * `input_wide`; every offset in and out counts units, not bytes.
 */
int re_run_interruptible(ReCompiled* re, const void* input, int input_len,
           int start_offset, int input_wide,
           int* out_start, int* out_end, int* out_num_captures,
           int* caps_start, int* caps_end, int max_captures, ReInterrupt* interrupt)
{
    if (!re || !re->bc) return RE_ERROR;

    /* Literal-prefix rejection. The prefix is ASCII, so a unit-wise search
     * finds exactly the occurrences of the pattern's leading characters. */
    if (re->prefix_len > 0) {
        int n = re->prefix_len;
        bool sticky = (lre_get_flags(re->bc) & LRE_FLAG_STICKY) != 0;
        long found = -1;
        if (start_offset > input_len) return RE_NO_MATCH;
        if (re->anchored || sticky) {
            /* the match can only start at start_offset */
            if (re->anchored && start_offset != 0) return RE_NO_MATCH;
            if (input_len - start_offset < n) return RE_NO_MATCH;
            for (int i = 0; i < n; i++) {
                unsigned u = input_wide ? ((const uint16_t*)input)[start_offset + i]
                                        : ((const uint8_t*)input)[start_offset + i];
                if (u != (unsigned char)re->prefix[i]) return RE_NO_MATCH;
            }
            found = start_offset;
        } else {
            found = re_find_lit(input, input_wide, start_offset, input_len,
                                re->prefix, n, re->prefix_rare);
            if (found < 0) return RE_NO_MATCH;
            /* Every match starts at or after this first prefix occurrence. */
            start_offset = (int)found;
        }
        if (re->literal_only) {
            if (out_start) *out_start = (int)found;
            if (out_end) *out_end = (int)found + n;
            if (out_num_captures) *out_num_captures = 0;
            return RE_MATCH;
        }
    }

    if (start_offset >= 0 && re->required_len > 0) {
        if (start_offset > input_len) return RE_NO_MATCH;
        if (re_find_lit(input, input_wide, start_offset, input_len,
                        re->required, re->required_len, re->required_rare) < 0)
            return RE_NO_MATCH;
    }

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
    /* The buffer also holds the quantifier registers after the captures. */
    int alloc_count = lre_get_alloc_count(re->bc);
    if (alloc_count > RE_MAX_CAPTURES * 2) {
        capture = (uint8_t**)calloc((size_t)alloc_count, sizeof(uint8_t*));
        if (!capture) return RE_ERROR;
    }

    /* cbuf_type 0 reads one byte per unit and 1 reads two. lre_exec derives
     * is_unicode from the compiled bytecode and promotes 1 to 2 itself
     * (surrogate-pair combining) under the u or v flag; the stride is 2 bytes
     * either way, so wide input is always passed as 1. A Latin-1 string holds
     * no surrogate, so unicode mode needs no promotion there. */
    int ret = lre_exec_ex(capture, re->bc, (const uint8_t*)input, start_offset, input_len,
                          input_wide ? 1 : 0, interrupt,
                          re->has_first_set ? &re->first_set : NULL);
    if (ret == RE_MATCH) {
        size_t shift = input_wide ? 1 : 0;
        const uint8_t* base = (const uint8_t*)input;
#define UNIT_OFFSET(p) ((p) ? (int)((size_t)((p) - base) >> shift) : -1)
        if (out_start) *out_start = UNIT_OFFSET(capture[0]);
        if (out_end)   *out_end   = UNIT_OFFSET(capture[1]);
        if (out_num_captures) *out_num_captures = total_captures - 1;
        for (int i = 1; i < total_captures && (i - 1) < max_captures; i++) {
            caps_start[i - 1] = UNIT_OFFSET(capture[i * 2]);
            caps_end[i - 1]   = UNIT_OFFSET(capture[i * 2 + 1]);
        }
#undef UNIT_OFFSET
        if (capture != capture_stack) free(capture);
        return RE_MATCH;
    }
    if (capture != capture_stack) free(capture);
    if (ret == 0) return RE_NO_MATCH;
    return RE_ERROR;
}

/* Predicates the native regexp backend needs. libregexp and libunicode keep
 * them as static inline functions in their headers, which C3 cannot call, so
 * they are exported here; the matcher itself is C3. */
uint32_t re_canonicalize(uint32_t c, bool is_unicode)
{
    return (uint32_t)lre_canonicalize(c, is_unicode);
}

bool re_is_space(uint32_t c)
{
    return lre_is_space(c) != 0;
}

bool re_is_word_byte(uint32_t c)
{
    return c < 256 && lre_is_word_byte((uint8_t)c) != 0;
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

int re_run(ReCompiled* re, const void* input, int input_len,
           int start_offset, int input_wide,
           int* out_start, int* out_end, int* out_num_captures,
           int* caps_start, int* caps_end, int max_captures)
{
    return re_run_interruptible(re, input, input_len, start_offset, input_wide,
        out_start, out_end, out_num_captures, caps_start, caps_end, max_captures, NULL);
}
