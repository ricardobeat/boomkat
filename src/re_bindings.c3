/*
 * RegExp C bindings: C3 interop with QuickJS libregexp through re_wrapper
 */
module duktape::re_bindings;

extern fn void* re_compile(char* pattern, usz pattern_len,
                           int flags, char* error_msg, int error_msg_size);

extern fn int re_exec(void* re, char* input, int input_len,
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
 * realistic patterns; regexps with more captures heap-allocate in re_exec. */
const int RE_MAX_CAPTURES = 256;
