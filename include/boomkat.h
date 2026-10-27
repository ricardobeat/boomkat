/* C99 embedding API. A runtime owns a heap; each context is a realm.
 * Values may cross contexts in one runtime. Runtime operations run on one thread,
 * except bk_request_interrupt, which may run concurrently while the runtime lives.
 *
 * Value results are owned GC roots; release each with bk_free_value.
 * All value arguments are borrowed, including property setters and bk_throw.
 * C callbacks borrow this/argv and transfer an owned result to the engine.
 * BK_EXCEPTION reports a failure; bk_get_exception transfers the thrown value.
 * Eval and call run synchronous work only. The host schedules job checkpoints.
 */
#ifndef BOOMKAT_H
#define BOOMKAT_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#ifdef __cplusplus
extern "C" {
#endif
#if defined(_WIN32) && defined(BK_DLL)
#define BK_API __declspec(dllimport)
#else
#define BK_API
#endif

typedef struct bk_runtime_s *bk_runtime;
typedef struct bk_ctx_s *bk_ctx;
typedef uint64_t bk_value;
#define BK_EXCEPTION ((bk_value)0)
static inline int bk_is_exception(bk_value value) { return value == BK_EXCEPTION; }

/* BEGIN GENERATED status (scripts/gen_abi_header.py) */
typedef enum {
    BK_OK            =  0,
    BK_ERR_NOMEM     = -1,  /* allocation failed */
    BK_ERR_SYNTAX    = -2,  /* compile failed */
    BK_ERR_THROW     = -3,  /* uncaught JS exception */
    BK_ERR_INTERNAL  = -4,  /* engine fault with no JS error attached */
    BK_ERR_INVALID   = -5,  /* null/bad argument, or a handle from elsewhere */
    BK_ERR_TYPE      = -6,  /* value is not of the requested type */
    BK_ERR_FULL      = -7,  /* buffer too small, or the registry is full */
    BK_ERR_INTERRUPT = -8,  /* aborted by the interrupt handler */
    BK_ERR_ENCODING  = -9   /* invalid UTF-8 input, or a lone surrogate in strict mode */
} bk_status;
/* END GENERATED status */

/* BEGIN GENERATED type (scripts/gen_abi_header.py) */
typedef enum {
    BK_TYPE_UNDEFINED = 0,
    BK_TYPE_NULL      = 1,
    BK_TYPE_BOOLEAN   = 2,
    BK_TYPE_NUMBER    = 3,
    BK_TYPE_STRING    = 4,
    BK_TYPE_OBJECT    = 5,
    BK_TYPE_FUNCTION  = 6,
    BK_TYPE_OTHER     = 7   /* symbol, bigint, etc. */
} bk_type;
/* END GENERATED type */

/* BEGIN GENERATED utf8_mode (scripts/gen_abi_header.py) */
typedef enum {
    BK_UTF8_REPLACE = 0,  /* lone surrogates become U+FFFD */
    BK_UTF8_STRICT  = 1   /* lone surrogates fail with BK_ERR_ENCODING */
} bk_utf8_mode;
/* END GENERATED utf8_mode */

/* BEGIN GENERATED errkind (scripts/gen_abi_header.py) */
typedef enum {
    BK_ERROR           = 0,
    BK_ERROR_TYPE      = 1,
    BK_ERROR_RANGE     = 2,
    BK_ERROR_REFERENCE = 3,
    BK_ERROR_SYNTAX    = 4
} bk_error_kind;
/* END GENERATED errkind */

/* A context that owns its own runtime, for hosts with one realm. bk_destroy
 * releases both; on a bk_new_context context it acts as bk_free_context. */
BK_API bk_ctx bk_create(void);
BK_API void bk_destroy(bk_ctx ctx);

/* Free contexts before their runtime. Escaped objects/functions retain their
 * realm until runtime destruction. Context release never destroys sibling realms.
 * Callback contexts are stable and may equal the caller's context. */
BK_API bk_runtime bk_new_runtime(void);
BK_API void bk_free_runtime(bk_runtime runtime);
BK_API bk_ctx bk_new_context(bk_runtime runtime);
BK_API void bk_free_context(bk_ctx ctx);
BK_API bk_runtime bk_get_runtime(bk_ctx ctx);
BK_API void bk_set_runtime_opaque(bk_runtime runtime, void *opaque);
BK_API void *bk_get_runtime_opaque(bk_runtime runtime);
BK_API void bk_set_context_opaque(bk_ctx ctx, void *opaque);
BK_API void *bk_get_context_opaque(bk_ctx ctx);
BK_API const char *bk_version(void);

enum { BK_EVAL_GLOBAL = 0, BK_EVAL_MODULE = 1, BK_EVAL_STRICT = 2 };
BK_API bk_value bk_eval_ex(bk_ctx ctx, const char *source, size_t length,
                           const char *filename, unsigned flags);
/* Sloppy global script from a NUL-terminated string. */
static inline bk_value bk_eval(bk_ctx ctx, const char *source) {
    return bk_eval_ex(ctx, source, strlen(source), NULL, BK_EVAL_GLOBAL);
}
BK_API bk_status bk_define_module(bk_ctx ctx, const char *name, size_t name_len,
                                  const char *source, size_t length);
typedef enum { BK_JSX_DEFAULT, BK_JSX_CLASSIC, BK_JSX_AUTOMATIC } bk_jsx_runtime;
BK_API bk_status bk_set_jsx(bk_ctx ctx, int enable, bk_jsx_runtime runtime,
                            const char *import_source, const char *factory, const char *fragment);

/* execute_pending_job returns 1 for a job, 0 for an empty/reentrant queue, or a
 * negative status. *ctx names the job's realm, including on failure.
 * run_jobs drains to completion and reports unhandled rejections at that checkpoint. */
BK_API int bk_is_job_pending(bk_runtime runtime);
BK_API int bk_execute_pending_job(bk_runtime runtime, bk_ctx *ctx);
BK_API bk_status bk_run_jobs(bk_runtime runtime);

BK_API void bk_free_value(bk_ctx ctx, bk_value value);
BK_API bk_value bk_dup_value(bk_ctx ctx, bk_value value);
BK_API bk_value bk_get_exception(bk_ctx ctx);
/* Diagnostics are context-owned; reading them never executes JS. Successful
 * operations may clear diagnostics; pending exceptions survive until taken. */
BK_API const char *bk_get_error_message(bk_ctx ctx);
BK_API bk_status bk_get_error_code(bk_ctx ctx);
typedef struct {
    bk_status code;
    int line;
    int col;
    const char *script_name;
} bk_error_info;
BK_API bk_status bk_get_error_info(bk_ctx ctx, bk_error_info *out);
BK_API const char *bk_status_str(bk_status status);
BK_API const char *bk_type_str(bk_type type);

BK_API bk_type bk_get_type(bk_ctx ctx, bk_value value);
BK_API bk_status bk_read_number(bk_ctx ctx, bk_value value, double *out);
BK_API bk_status bk_read_bool(bk_ctx ctx, bk_value value, int *out);
/* UTF-8 with the lone-surrogate policy of BK_UTF8_REPLACE. Measure with buffer=NULL;
 * length excludes NUL and, on BK_ERR_FULL, reports the size needed. Fill needs
 * length+1 bytes. */
BK_API bk_status bk_read_string(bk_ctx ctx, bk_value value, char *buffer, size_t capacity, size_t *length);
BK_API bk_status bk_read_string_utf8(bk_ctx ctx, bk_value value, bk_utf8_mode mode,
                                     char *buffer, size_t capacity, size_t *length);
/* UTF-16 code units, lone surrogates kept, no terminator. Capacity and length
 * count units; on BK_ERR_FULL, length reports the units needed. */
BK_API bk_status bk_read_string_utf16(bk_ctx ctx, bk_value value, uint16_t *buffer,
                                      size_t capacity, size_t *length);
/* Length in UTF-16 code units; 0 when value is not a string. */
BK_API size_t bk_string_length(bk_ctx ctx, bk_value value);
BK_API double bk_to_number(bk_ctx ctx, bk_value value);
BK_API int bk_to_bool(bk_ctx ctx, bk_value value);
BK_API bk_value bk_to_string(bk_ctx ctx, bk_value value);
/* Context-owned UTF-8, valid until the fourth following bk_cstr call on the
 * runtime, so several results can be live in one printf. NULL if ToString threw. */
BK_API const char *bk_cstr(bk_ctx ctx, bk_value value, size_t *length);
/* UTF-8 storage stays valid until explicitly freed, including across reentry. */
BK_API const char *bk_to_cstring(bk_ctx ctx, bk_value value, size_t *length);
BK_API void bk_free_cstring(bk_ctx ctx, const char *string);

BK_API bk_value bk_new_number(bk_ctx ctx, double value);
BK_API bk_value bk_new_bool(bk_ctx ctx, int value);
BK_API bk_value bk_new_null(bk_ctx ctx);
BK_API bk_value bk_new_undefined(bk_ctx ctx);
/* Fails with BK_ERR_ENCODING and returns BK_EXCEPTION on invalid UTF-8. */
BK_API bk_value bk_new_string(bk_ctx ctx, const char *utf8, size_t length);
/* Each byte is the code point of the same value. */
BK_API bk_value bk_new_string_latin1(bk_ctx ctx, const uint8_t *chars, size_t length);
/* Lone surrogates are kept as given. */
BK_API bk_value bk_new_string_utf16(bk_ctx ctx, const uint16_t *units, size_t length);
BK_API bk_value bk_new_object(bk_ctx ctx);
BK_API bk_value bk_new_array(bk_ctx ctx);
BK_API bk_value bk_new_array_from(bk_ctx ctx, const bk_value *elements, unsigned count);
BK_API bk_value bk_get_global_object(bk_ctx ctx);
BK_API bk_value bk_get_property(bk_ctx ctx, bk_value object, const char *key, size_t key_len);
BK_API bk_value bk_get_property_uint32(bk_ctx ctx, bk_value object, unsigned index);
BK_API bk_status bk_set_property(bk_ctx ctx, bk_value object, const char *key, size_t key_len, bk_value value);
BK_API bk_status bk_set_property_uint32(bk_ctx ctx, bk_value object, unsigned index, bk_value value);
BK_API bk_status bk_has_property(bk_ctx ctx, bk_value object, const char *key, size_t key_len, int *out);
BK_API bk_status bk_delete_property(bk_ctx ctx, bk_value object, const char *key, size_t key_len, int *out);
BK_API bk_value bk_get_own_property_names(bk_ctx ctx, bk_value object);
BK_API bk_status bk_set_global_property(bk_ctx ctx, const char *name, size_t length, bk_value value);
/* Calls accept up to 65535 arguments; larger counts throw RangeError. */
BK_API bk_value bk_call(bk_ctx ctx, bk_value function, bk_value this_value, const bk_value *argv, unsigned argc);

/* Arguments/this borrow the current call and must be duplicated to escape it.
 * A callback returns an owned handle (including undefined), or BK_EXCEPTION.
 * bk_throw/error set the pending exception and return BK_EXCEPTION. */
typedef bk_value (*bk_c_function)(bk_ctx ctx, bk_value this_value,
                                  unsigned argc, const bk_value *argv, void *opaque);
#define BK_CTOR 1u
BK_API bk_value bk_new_c_function(bk_ctx ctx, bk_c_function callback, const char *name,
                                  int arity, unsigned flags, void *opaque);
typedef struct {
    const char *name;
    bk_c_function fn;
    int arity;
    unsigned flags;
    void *udata;
} bk_fn_def;
#define BK_FN_END { NULL, NULL, 0, 0u, NULL }
BK_API bk_status bk_set_function_list(bk_ctx ctx, bk_value target, const bk_fn_def *functions);
/* A bk_host_fn reads its call through the context and answers with bk_return;
 * returning without one yields undefined, and a pending throw wins over both. */
typedef void (*bk_host_fn)(bk_ctx ctx, void *opaque);
/* target 0 installs the function as a global. */
BK_API bk_status bk_register_fn(bk_ctx ctx, bk_value target, const char *name,
                                bk_host_fn fn, int arity, unsigned flags, void *opaque);
/* Call accessors (argc, arg, this, new.target) work in either callback kind and
 * borrow the current call. Arguments past argc read as undefined; outside a
 * callback they return 0. */
BK_API unsigned bk_argc(bk_ctx ctx);
BK_API bk_value bk_arg(bk_ctx ctx, unsigned index);
BK_API bk_value bk_this(bk_ctx ctx);
/* Stage the result of a bk_host_fn. The value is borrowed; a later call replaces it. */
BK_API bk_status bk_return(bk_ctx ctx, bk_value value);
BK_API bk_value bk_get_new_target(bk_ctx ctx);
BK_API int bk_is_constructor_call(bk_ctx ctx);
BK_API bk_value bk_throw_error(bk_ctx ctx, bk_error_kind kind, const char *message);
BK_API bk_value bk_throw(bk_ctx ctx, bk_value value);

/* The tracker runs on the engine thread; promise/reason are borrowed. It must
 * not execute JS or replace itself. Report unhandled rejections after a checkpoint. */
typedef void (*bk_promise_rejection_fn)(bk_ctx ctx, uint64_t promise_id,
    bk_value promise, bk_value reason, int handled, void *opaque);
BK_API void bk_set_promise_rejection_tracker(bk_runtime runtime, bk_promise_rejection_fn callback, void *opaque);
/* Poll callbacks must not reenter the engine. Interrupts are uncatchable and
 * atomic requests remain latched until cleared. Join watchdogs before teardown. */
typedef int (*bk_interrupt_fn)(bk_runtime runtime, void *opaque);
BK_API void bk_set_interrupt(bk_runtime runtime, bk_interrupt_fn callback, void *opaque);
BK_API void bk_request_interrupt(bk_runtime runtime);
BK_API void bk_clear_interrupt(bk_runtime runtime);
/* Resident-memory limit in bytes; zero disables the process-wide RSS check. */
BK_API void bk_set_memory_limit(bk_runtime runtime, uint64_t bytes);

/* Shorthands over the calls above; static inline, so they add no ABI symbols. */
static inline int bk_exec(bk_ctx ctx, const char *source) {
    bk_value value = bk_eval(ctx, source);
    if (bk_is_exception(value)) return 1;
    bk_free_value(ctx, value);
    return 0;
}
static inline void bk_free(bk_ctx ctx, bk_value value) { bk_free_value(ctx, value); }
static inline const char *bk_error(bk_ctx ctx) { return bk_get_error_message(ctx); }
static inline bk_value bk_str(bk_ctx ctx, const char *utf8) {
    return bk_new_string(ctx, utf8, strlen(utf8));
}
static inline bk_value bk_get(bk_ctx ctx, bk_value object, const char *key) {
    return bk_get_property(ctx, object, key, strlen(key));
}
static inline bk_status bk_set(bk_ctx ctx, bk_value object, const char *key, bk_value value) {
    return bk_set_property(ctx, object, key, strlen(key), value);
}
static inline bk_status bk_set_global(bk_ctx ctx, const char *name, bk_value value) {
    return bk_set_global_property(ctx, name, strlen(name), value);
}

static inline int bk_is_undefined(bk_ctx c, bk_value v) { return bk_get_type(c, v) == BK_TYPE_UNDEFINED; }
static inline int bk_is_null(bk_ctx c, bk_value v)      { return bk_get_type(c, v) == BK_TYPE_NULL; }
static inline int bk_is_bool(bk_ctx c, bk_value v)      { return bk_get_type(c, v) == BK_TYPE_BOOLEAN; }
static inline int bk_is_number(bk_ctx c, bk_value v)    { return bk_get_type(c, v) == BK_TYPE_NUMBER; }
static inline int bk_is_string(bk_ctx c, bk_value v)    { return bk_get_type(c, v) == BK_TYPE_STRING; }
static inline int bk_is_object(bk_ctx c, bk_value v)    { return bk_get_type(c, v) == BK_TYPE_OBJECT; }
static inline int bk_is_function(bk_ctx c, bk_value v)  { return bk_get_type(c, v) == BK_TYPE_FUNCTION; }

static inline bk_status bk_return_owned(bk_ctx c, bk_value v) {
    bk_status status = bk_return(c, v);
    bk_free_value(c, v);
    return status;
}
static inline bk_status bk_return_number(bk_ctx c, double d) { return bk_return_owned(c, bk_new_number(c, d)); }
static inline bk_status bk_return_bool(bk_ctx c, int b)      { return bk_return_owned(c, bk_new_bool(c, b)); }
static inline bk_status bk_return_null(bk_ctx c)             { return bk_return_owned(c, bk_new_null(c)); }
static inline bk_status bk_return_str(bk_ctx c, const char *utf8) {
    return bk_return_owned(c, bk_str(c, utf8));
}

#ifdef __cplusplus
}
#endif
#endif
