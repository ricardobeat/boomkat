/*
 * RegExp C bindings: C3 interop with QuickJS libregexp through re_wrapper
 */
module boomkat::re_bindings @feat(!NO_REGEXP);

extern fn void* re_compile(char* pattern, usz pattern_len,
                           int flags, char* error_msg, int error_msg_size);

/* Named re_run rather than re_exec: glibc exports its own legacy `re_exec`,
 * and since the shared library exports every engine symbol, an ELF loader
 * bound this call to libc's unrelated function and every JS regexp segfaulted
 * inside libc. macOS two-level namespaces hid the clash. */
extern fn int re_run(void* re, void* input, int input_len,
                     int start_offset, int input_wide,
                     int* out_start, int* out_end, int* out_num_captures,
                     int* caps_start, int* caps_end, int max_captures);

extern fn void re_free(void* re);

extern fn void re_ref(void* re);

extern fn char* re_get_groupnames(void* re);

extern fn int re_get_capture_count(void* re);

extern fn int re_run_interruptible(void* re, void* input, int input_len,
    int start_offset, int input_wide,
    int* out_start, int* out_end, int* out_num_captures,
    int* caps_start, int* caps_end, int max_captures, ReInterrupt* interrupt);
