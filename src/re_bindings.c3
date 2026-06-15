/// RegExp bindings — now using the pure C3 tiny_re engine
module tinyduck::re_bindings;

import tinyduck::tiny_re;

/* Re-export constants for other modules */
const int RE_FLAG_IGNORECASE = tiny_re::RE_FLAG_IGNORECASE;
const int RE_FLAG_MULTILINE  = tiny_re::RE_FLAG_MULTILINE;
const int RE_FLAG_DOTALL     = tiny_re::RE_FLAG_DOTALL;
const int RE_MATCH    = tiny_re::RE_MATCH;
const int RE_NO_MATCH = tiny_re::RE_NO_MATCH;
const int RE_ERROR    = tiny_re::RE_ERROR;
const int RE_MAX_CAPTURES = tiny_re::RE_MAX_CAPTURES;

/* Wrapper API called by the rest of the engine. */
fn void* re_compile(char* pattern, usz pattern_len,
                    int flags, char* error_msg, int error_msg_size) {
    $if $feature(NO_REGEXP):
        return null;
    $else
        tiny_re::ReCompiled*? r = tiny_re::tiny_re_compile(pattern, pattern_len, flags, error_msg, error_msg_size);
        if (try compiled = r) {
            return (void*)compiled;
        }
        return null;
    $endif
}

fn int re_exec(void* re, char* input, int input_len,
               int start_offset,
               int* out_start, int* out_end, int* out_num_captures,
               int* caps_start, int* caps_end, int max_captures) {
    $if $feature(NO_REGEXP):
        return RE_ERROR;
    $else
        return tiny_re::tiny_re_exec((tiny_re::ReCompiled*)re, input, input_len, start_offset,
                                     out_start, out_end, out_num_captures,
                                     caps_start, caps_end, max_captures);
    $endif
}

fn void re_free(void* re) {
    $if !$feature(NO_REGEXP):
        tiny_re::tiny_re_free((tiny_re::ReCompiled*)re);
    $endif
}
