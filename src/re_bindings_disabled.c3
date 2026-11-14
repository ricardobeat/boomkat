// No regexp object or bytecode instruction can enter this provider.
module boomkat::re_bindings @feat(NO_REGEXP);

fn void* re_compile(char* pattern, usz pattern_len, int flags, char* error_msg, int error_msg_size) { return null; }
fn int re_run(void* re, void* input, int input_len, int start_offset, int input_wide, int* caps, int cap_slots, ReInterrupt* interrupt) { return 0; }
fn int re_run_direct(void* re, char* data, uint len, bool wide, uint start, int* caps, int cap_slots, ReInterrupt* interrupt) { return 0; }
fn int re_group_count(void* re) { return 0; }
fn char[] re_whole_literal(void* re) { return {}; }
fn void re_free(void* re) { }
fn void re_ref(void* re) { }
fn char* re_get_groupnames(void* re) { return null; }
fn int re_get_capture_count(void* re) { return 0; }
fn int re_captures(void* re) { return 0; }
fn bool re_has_group_names(void* re) { return false; }
