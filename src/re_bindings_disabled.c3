// No regexp object or bytecode instruction can enter this provider.
module boomkat::re_bindings @feat(NO_REGEXP);

fn void* re_compile(char* pattern, usz pattern_len, int flags, char* error_msg, int error_msg_size) { return null; }
fn int re_run(void* re, void* input, int input_len, int start_offset, int input_wide, int* out_start, int* out_end, int* out_num_captures, int* caps_start, int* caps_end, int max_captures) { return 0; }
fn void re_free(void* re) { }
fn void re_ref(void* re) { }
fn char* re_get_groupnames(void* re) { return null; }
fn int re_get_capture_count(void* re) { return 0; }

fn int re_run_interruptible(void* re, void* input, int input_len, int start_offset, int input_wide, int* out_start, int* out_end, int* out_num_captures, int* caps_start, int* caps_end, int max_captures, ReInterrupt* interrupt) { return 0; }
