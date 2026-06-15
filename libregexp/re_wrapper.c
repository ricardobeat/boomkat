/*
 * RegExp wrapper — implementation using QuickJS libregexp
 *
 * When built with -DNO_REGEXP, all functions become no-ops and no
 * libregexp symbols are referenced.
 */
#include <stdlib.h>
#include <string.h>
#include "libregexp.h"
#include "re_wrapper.h"

/* User-provided callbacks for libregexp */
bool lre_check_stack_overflow(void *opaque, size_t alloca_size)
{
    (void)opaque; (void)alloca_size;
    return false;
}

int lre_check_timeout(void *opaque)
{
    (void)opaque;
    return 0;
}

void *lre_realloc(void *opaque, void *ptr, size_t size)
{
    (void)opaque;
    if (size == 0) { free(ptr); return NULL; }
    return realloc(ptr, size);
}

#ifndef NO_REGEXP

struct ReCompiled {
    uint8_t* bc;
    int      bc_len;
    int      capture_count;
};

ReCompiled* re_compile_extern(const char* pattern, size_t pattern_len,
                              int flags, char* error_msg, int error_msg_size)
{
    int lre_flags = 0;
    if (flags & RE_FLAG_IGNORECASE) lre_flags |= LRE_FLAG_IGNORECASE;
    if (flags & RE_FLAG_MULTILINE)  lre_flags |= LRE_FLAG_MULTILINE;
    if (flags & RE_FLAG_DOTALL)     lre_flags |= LRE_FLAG_DOTALL;

    char internal_error[128];
    int bc_len;
    uint8_t* bc = lre_compile(&bc_len, internal_error, sizeof(internal_error),
                               pattern, pattern_len, lre_flags, NULL);
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

    if (error_msg && error_msg_size > 0) error_msg[0] = '\0';
    return re;
}

int re_exec_extern(ReCompiled* re, const char* input, int input_len,
                   int start_offset,
                   int* out_start, int* out_end, int* out_num_captures,
                   int* caps_start, int* caps_end, int max_captures)
{
    if (!re || !re->bc) return RE_ERROR;

    int total_captures = re->capture_count;
    if (total_captures > RE_MAX_CAPTURES) total_captures = RE_MAX_CAPTURES;

    uint8_t* capture[RE_MAX_CAPTURES * 2];
    int cbuf_type = 0;

    int ret = lre_exec(capture, re->bc,
                       (const uint8_t*)input, start_offset, input_len,
                       cbuf_type, NULL);

    if (ret == RE_MATCH) {
        if (out_start) *out_start = capture[0] ? (int)(capture[0] - (const uint8_t*)input) : -1;
        if (out_end)   *out_end   = capture[1] ? (int)(capture[1] - (const uint8_t*)input) : -1;
        if (out_num_captures) *out_num_captures = total_captures - 1;

        for (int i = 1; i < total_captures && (i - 1) < max_captures; i++) {
            int idx = i * 2;
            int s = capture[idx] ? (int)(capture[idx] - (const uint8_t*)input) : -1;
            int e = capture[idx + 1] ? (int)(capture[idx + 1] - (const uint8_t*)input) : -1;
            caps_start[i - 1] = s;
            caps_end[i - 1] = e;
        }
        return RE_MATCH;
    }

    if (ret == 0) return RE_NO_MATCH;
    return RE_ERROR;
}

void re_free_extern(ReCompiled* re)
{
    if (re) {
        if (re->bc) lre_realloc(NULL, re->bc, 0);
        free(re);
    }
}

#else /* NO_REGEXP — stubs, no libregexp dependency */

ReCompiled* re_compile_extern(const char* pattern, size_t pattern_len,
                              int flags, char* error_msg, int error_msg_size)
{
    (void)pattern; (void)pattern_len; (void)flags;
    if (error_msg && error_msg_size > 0) {
        error_msg[0] = '\0';
    }
    return NULL;
}

int re_exec_extern(ReCompiled* re, const char* input, int input_len,
                   int start_offset,
                   int* out_start, int* out_end, int* out_num_captures,
                   int* caps_start, int* caps_end, int max_captures)
{
    (void)re; (void)input; (void)input_len; (void)start_offset;
    (void)out_start; (void)out_end; (void)out_num_captures;
    (void)caps_start; (void)caps_end; (void)max_captures;
    return RE_ERROR;
}

void re_free_extern(ReCompiled* re)
{
    (void)re;
}

#endif /* NO_REGEXP */
