/*
 * RegExp C bindings — C3 interop with QuickJS libregexp via re_wrapper
 *
 * When built with `-D NO_REGEXP`, all functions return stub values (null / error)
 * and the libregexp C library is not linked, saving ~150+ KB of binary size.
 */
module duktape::re_bindings;

/* Constants matching re_wrapper.h */
const int RE_FLAG_IGNORECASE = 2;
const int RE_FLAG_MULTILINE  = 4;
const int RE_FLAG_DOTALL     = 8;

const int RE_MATCH    = 1;
const int RE_NO_MATCH = 0;
const int RE_ERROR    = -1;

const int RE_MAX_CAPTURES = 32;

/* Real extern fns — only referenced when NO_REGEXP is not set. */
extern fn void* re_compile_extern(char* pattern, usz pattern_len,
                                  int flags, char* error_msg, int error_msg_size);

extern fn int re_exec_extern(void* re, char* input, int input_len,
                             int start_offset,
                             int* out_start, int* out_end, int* out_num_captures,
                             int* caps_start, int* caps_end, int max_captures);

extern fn void re_free_extern(void* re);

/* Wrapper API called by the rest of the engine. */
fn void* re_compile(char* pattern, usz pattern_len,
                    int flags, char* error_msg, int error_msg_size) {
    $if $feature(NO_REGEXP):
        return null;
    $else
        return re_compile_extern(pattern, pattern_len, flags, error_msg, error_msg_size);
    $endif
}

fn int re_exec(void* re, char* input, int input_len,
               int start_offset,
               int* out_start, int* out_end, int* out_num_captures,
               int* caps_start, int* caps_end, int max_captures) {
    $if $feature(NO_REGEXP):
        return RE_ERROR;
    $else
        return re_exec_extern(re, input, input_len, start_offset,
                              out_start, out_end, out_num_captures,
                              caps_start, caps_end, max_captures);
    $endif
}

fn void re_free(void* re) {
    $if !$feature(NO_REGEXP):
        re_free_extern(re);
    $endif
}
