/*
 * bk_util.h — small C99 conveniences over the raw bk_ ABI.
 *
 * The ABI deliberately never hands out memory the caller must free: strings
 * come back through a two-call measure-then-fill protocol. That is the right
 * choice for an ABI but verbose at every call site, so these helpers wrap it.
 *
 * Nothing here is required to use the engine. It is ordinary C99 over the
 * public header, and you are meant to copy it into your own project.
 */

#ifndef BK_UTIL_H
#define BK_UTIL_H

#include <boomkat.h>

/*
 * Evaluate a NUL-terminated source string. Thin wrapper over bk_eval that
 * spares the caller a strlen at every call site.
 */
int bku_eval_cstr(bk_runtime rt, const char *src, bk_value *out_val);

/*
 * Read a JS string value into a freshly malloc'd, NUL-terminated UTF-8 buffer.
 *
 * Returns the buffer, which the CALLER must free(), or NULL if the value is
 * not a string or allocation failed. This is the one place in this file that
 * hands back owned memory; the ABI itself never does.
 */
char *bku_string_dup(bk_runtime rt, bk_value v);

/*
 * Evaluate `src` and convert the completion value to a string via JS String(),
 * so any type prints. Returns a malloc'd buffer the caller must free, or NULL
 * on error (use bk_last_error for the reason).
 */
char *bku_eval_to_string(bk_runtime rt, const char *src);

/* Human-readable name for a bk_type, for logging. Never NULL. */
const char *bku_type_name(int type);

/* Human-readable name for a bk_status code, for logging. Never NULL. */
const char *bku_status_name(int status);

#endif /* BK_UTIL_H */
