/*
 * jse_util.h — small C99 conveniences over the raw jse_ ABI.
 *
 * The ABI deliberately never hands out memory the caller must free: strings
 * come back through a two-call measure-then-fill protocol. That is the right
 * choice for an ABI but verbose at every call site, so these helpers wrap it.
 *
 * Nothing here is required to use the engine. It is ordinary C99 over the
 * public header, and you are meant to copy it into your own project.
 */

#ifndef JSE_UTIL_H
#define JSE_UTIL_H

#include <jse.h>

/*
 * Evaluate a NUL-terminated source string. Thin wrapper over jse_eval that
 * spares the caller a strlen at every call site.
 */
int jseu_eval_cstr(jse_runtime rt, const char *src, jse_value *out_val);

/*
 * Read a JS string value into a freshly malloc'd, NUL-terminated UTF-8 buffer.
 *
 * Returns the buffer, which the CALLER must free(), or NULL if the value is
 * not a string or allocation failed. This is the one place in this file that
 * hands back owned memory; the ABI itself never does.
 */
char *jseu_string_dup(jse_runtime rt, jse_value v);

/*
 * Evaluate `src` and convert the completion value to a string via JS String(),
 * so any type prints. Returns a malloc'd buffer the caller must free, or NULL
 * on error (use jse_last_error for the reason).
 */
char *jseu_eval_to_string(jse_runtime rt, const char *src);

/* Human-readable name for a jse_type, for logging. Never NULL. */
const char *jseu_type_name(int type);

/* Human-readable name for a jse_status code, for logging. Never NULL. */
const char *jseu_status_name(int status);

#endif /* JSE_UTIL_H */
