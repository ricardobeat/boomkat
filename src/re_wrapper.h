/*
 * RegExp wrapper — simplified C API for QuickJS libregexp
 *
 * Provides simple non-intrusive functions for C3 interop.
 */
#ifndef RE_WRAPPER_H
#define RE_WRAPPER_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle for a compiled regular expression */
typedef struct ReCompiled ReCompiled;

/* Flags */
#define RE_FLAG_IGNORECASE (1 << 1)
#define RE_FLAG_MULTILINE  (1 << 2)
#define RE_FLAG_DOTALL     (1 << 3)
#define RE_FLAG_UNICODE    (1 << 4) /* u flag */
#define RE_FLAG_STICKY     (1 << 5) /* y flag */
#define RE_FLAG_INDICES    (1 << 6) /* d flag */
#define RE_FLAG_UNICODE_SETS (1 << 7) /* v flag */

/* Return values */
#define RE_ERROR    (-1)
#define RE_NO_MATCH (0)
#define RE_MATCH    (1)

/* Maximum number of capture groups we support. The 256-slot stack buffer
 * covers realistic patterns including deep nesting (the 200-group test
 * S15.10.2.8_A3_T15). Regexps with more captures heap-allocate a
 * capture[] buffer in re_run(). */
#define RE_MAX_CAPTURES 256

/*
 * Compile a regexp pattern.
 * Returns NULL on failure (error_msg will be set).
 */
ReCompiled* re_compile(const char* pattern, size_t pattern_len,
                       int flags, char* error_msg, int error_msg_size);

typedef struct ReInterrupt {
    int (*poll)(void *opaque);
    void *opaque;
} ReInterrupt;

/*
 * Execute a compiled regexp against input.
 * Returns RE_MATCH, RE_NO_MATCH, or RE_ERROR.
 *
 * Named re_run, not re_exec: glibc exports a legacy BSD `re_exec` of its own,
 * and the shared library exports every engine symbol, so on ELF the dynamic
 * loader resolved this function's internal call sites to glibc's unrelated
 * one -- any JS regexp then segfaulted inside libc. macOS two-level namespaces
 * hid the clash entirely.
 *
 * If RE_MATCH, caps[2 * i] and caps[2 * i + 1] are the unit offsets of group
 * i's start and end (group 0 is the whole match), or -1 for a group that did
 * not participate, for the groups that fit in `cap_slots` (at least 2) ints.
 * `interrupt` may be NULL.
 */
int re_run(ReCompiled* re, const void* input, int input_len,
           int start_offset, int input_wide, int* caps, int cap_slots,
           ReInterrupt* interrupt);

#define RE_PREFILTER_NONE  (-1)
#define RE_PREFILTER_MATCH (-2)

enum { RE_LIT_REQUIRED, RE_LIT_PREFIX, RE_LIT_AT, RE_LIT_AT_ZERO };
int re_literal(ReCompiled* re, char* out, int* rare, int* where, int* whole);
int re_prefilter(ReCompiled* re, const void* input, int input_len, int start_offset,
                 int input_wide, int* caps);
bool re_unfiltered(ReCompiled* re);

/*
 * Free a compiled regexp (decrements its refcount; frees at zero).
 */
void re_free(ReCompiled* re);

/*
 * Take an additional reference to a shared compiled regexp.
 */
void re_ref(ReCompiled* re);

/*
 * Get pointer to group names buffer from compiled regexp.
 * Returns NULL if no named capture groups.
 * The returned buffer contains one null-terminated string per capture group
 * (index 1, 2, ...) in order. An empty string means the group is unnamed.
 */
const char* re_get_groupnames(ReCompiled* re);

/*
 * Get total number of captures (including group 0).
 */
int re_get_capture_count(ReCompiled* re);

#ifdef __cplusplus
}
#endif

#endif /* RE_WRAPPER_H */
