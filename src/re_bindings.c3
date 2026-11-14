/*
 * RegExp C bindings: C3 interop with QuickJS libregexp through re_wrapper
 */
module boomkat::re_bindings @feat(!NO_REGEXP);
import boomkat::re_native;

extern fn void* re_compile(char* pattern, usz pattern_len,
                           int flags, char* error_msg, int error_msg_size);

/* Named re_run rather than re_exec: glibc exports its own legacy `re_exec`,
 * and since the shared library exports every engine symbol, an ELF loader
 * bound this call to libc's unrelated function and every JS regexp segfaulted
 * inside libc. macOS two-level namespaces hid the clash. */
/* On a match caps[2 * i] and caps[2 * i + 1] bound group i (group 0 is the
 * match), -1 when it did not participate, for the groups `cap_slots` ints
 * hold (re_wrapper.h). */
extern fn int re_run(void* re, void* input, int input_len,
                     int start_offset, int input_wide, int* caps, int cap_slots,
                     ReInterrupt* interrupt);

/* re_run of `re` over `len` units of `data` from `start`, run by its compiled
 * body with nothing between when it has one, as re_run reports a run. */
fn int re_run_direct(void* re, char* data, uint len, bool wide, uint start, int* caps, int cap_slots,
                     ReInterrupt* interrupt) @inline {
    int ret = re_native::re_run_compiled(re, data, len, wide, start, caps, cap_slots, interrupt);
    if (ret >= 0) return ret;
    return re_run(re, data, (int)len, (int)start, wide ? 1 : 0, caps, cap_slots, interrupt);
}

// The groups of `re`, group 0 included, as its native program counts them; the
// most a pattern can have when it has none.
fn int re_group_count(void* re) @inline {
    re_native::ReNative* n = *(re_native::ReNative**)re;
    return n == null ? RE_MAX_CAPTURES : (int)n.prog.capture_count;
}

/* The literal every run of `re` is checked against (re_wrapper.h). */
extern fn int re_literal(void* re, char* out, int* rare, int* where, int* whole);

extern fn void re_free(void* re);

extern fn void re_ref(void* re);

extern fn char* re_get_groupnames(void* re);

extern fn int re_get_capture_count(void* re);

/* The predicates the native regexp backend needs, which libregexp and
 * libunicode keep as static inline functions in their headers. */
extern fn uint re_canonicalize(uint c, bool is_unicode);

extern fn bool re_is_space(uint c);

extern fn bool re_is_word_byte(uint c);

/* The first-unit filter libregexp computed for the pattern, for the native
 * matcher's position scan. False when there is none to use. */
extern fn bool re_first_set(void* re, uint* bits, int* wide, int* single,
                            int* at_start, int* at_end);

/* Force the native matcher on or off, which the differential suites use to run
 * the same pattern through both. */
extern fn void re_set_native(int enabled);

/* The compiled libregexp bytecode and its length, owned by the compiled regexp. */
extern fn char* re_bytecode(void* re, int* len);
