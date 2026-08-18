/*
 * RegExp C bindings: C3 interop with QuickJS libregexp through re_wrapper
 */
module boomkat::re_bindings;

extern fn void* re_compile(char* pattern, usz pattern_len,
                           int flags, char* error_msg, int error_msg_size);

/* Named re_run rather than re_exec: glibc exports its own legacy `re_exec`,
 * and since the shared library exports every engine symbol, an ELF loader
 * bound this call to libc's unrelated function and every JS regexp segfaulted
 * inside libc. macOS two-level namespaces hid the clash. */
extern fn int re_run(void* re, char* input, int input_len,
                     int start_offset, int input_is_ascii,
                     int* out_start, int* out_end, int* out_num_captures,
                     int* caps_start, int* caps_end, int max_captures);

extern fn void re_free(void* re);

extern fn void re_ref(void* re);

extern fn char* re_get_groupnames(void* re);

extern fn int re_get_capture_count(void* re);

/* Constants matching re_wrapper.h */
const int RE_FLAG_IGNORECASE = 2;
const int RE_FLAG_MULTILINE  = 4;
const int RE_FLAG_DOTALL     = 8;
const int RE_FLAG_UNICODE    = 16;
const int RE_FLAG_STICKY     = 32;
const int RE_FLAG_INDICES    = 64;
const int RE_FLAG_UNICODE_SETS = 128;

const int RE_MATCH    = 1;

/* Must match libregexp/re_wrapper.h. The 256-slot stack buffer covers
 * realistic patterns; regexps with more captures heap-allocate in re_run.
 *
 * On a match, re_run fills caps_start/caps_end for every index it reports
 * through out_num_captures, writing -1 for groups that did not participate.
 * Callers therefore declare those arrays `@noinit` and read only the reported
 * range: zeroing 2 KiB per call showed up as ~10% of regexp-heavy benchmarks. */
const int RE_MAX_CAPTURES = 256;
