/* C99 embedding API. A runtime owns a heap; each context is a realm.
 * Values may cross contexts in one runtime. Runtime operations run on one thread,
 * except bk_request_interrupt, which may run concurrently while the runtime lives.
 *
 * Outside any local scope, value results are owned GC roots; release each
 * with bk_free_value. Inside a local scope, including a C callback's own call,
 * results are locals that die when the scope closes.
 * All value arguments are borrowed, including property setters and bk_throw.
 * C callbacks borrow this/argv and return a borrowed handle.
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
/* Immediate handles: valid with any context, never freed (bk_free_value
 * ignores them). Every call whose result is one of these values returns the
 * constant instead of a registry root. */
#define BK_UNDEFINED ((bk_value)1)
#define BK_NULL      ((bk_value)2)
#define BK_TRUE      ((bk_value)3)
#define BK_FALSE     ((bk_value)4)
#define BK_BOOL(b)   ((b) ? BK_TRUE : BK_FALSE)

/* BEGIN GENERATED status (scripts/gen_abi_header.py) */
typedef enum {
    BK_OK              =   0,
    BK_ERR_NOMEM       =  -1,  /* allocation failed */
    BK_ERR_SYNTAX      =  -2,  /* compile failed */
    BK_ERR_THROW       =  -3,  /* uncaught JS exception */
    BK_ERR_INTERNAL    =  -4,  /* engine fault with no JS error attached */
    BK_ERR_INVALID     =  -5,  /* null/bad argument, or a handle from elsewhere */
    BK_ERR_TYPE        =  -6,  /* value is not of the requested type */
    BK_ERR_FULL        =  -7,  /* buffer too small, or the registry is full */
    BK_ERR_INTERRUPT   =  -8,  /* aborted by the interrupt handler */
    BK_ERR_ENCODING    =  -9,  /* invalid UTF-8 input, or a lone surrogate in strict mode */
    BK_ERR_UNSUPPORTED = -10   /* feature compiled out of this build */
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
    BK_TYPE_SYMBOL    = 7,
    BK_TYPE_BIGINT    = 8
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
/* Runtime options. alloc, realloc and free come as a set (all or none) and
 * receive alloc_opaque. realloc behaves as C realloc: a NULL pointer
 * allocates, and a zero size frees and returns NULL. fatal must not return; NULL prints the message and aborts. The
 * compiler, lexer, regexp and shared-memory blocks still allocate through
 * libc. */
typedef struct {
    void *(*alloc)(void *opaque, size_t size);
    void *(*realloc)(void *opaque, void *ptr, size_t size);
    void  (*free)(void *opaque, void *ptr);
    void  *alloc_opaque;
    void  (*fatal)(void *opaque, const char *message);
} bk_runtime_options;

/* options may be NULL for the defaults. Returns NULL on failure, including a
 * partial allocator set. */
BK_API bk_runtime bk_new_runtime(const bk_runtime_options *options);
/* Memory from the runtime's allocator. bk_realloc(NULL) allocates and a zero
 * size frees. */
BK_API void *bk_alloc(bk_runtime runtime, size_t size);
BK_API void *bk_realloc(bk_runtime runtime, void *ptr, size_t size);
BK_API void  bk_free_memory(bk_runtime runtime, void *ptr);
BK_API void bk_free_runtime(bk_runtime runtime);
BK_API bk_ctx bk_new_context(bk_runtime runtime);
BK_API void bk_free_context(bk_ctx ctx);
BK_API bk_runtime bk_get_runtime(bk_ctx ctx);
/* Embedder data: BK_DATA_SLOTS pointers per runtime and per context, NULL
 * until set. Slot 3 is reserved for boomkat.hpp; slots 0-2 belong to the host.
 * Out-of-range slots are ignored on set and read as NULL. */
#define BK_DATA_SLOTS 4
BK_API void bk_set_runtime_data(bk_runtime runtime, unsigned slot, void *data);
BK_API void *bk_get_runtime_data(bk_runtime runtime, unsigned slot);
BK_API void bk_set_context_data(bk_ctx ctx, unsigned slot, void *data);
BK_API void *bk_get_context_data(bk_ctx ctx, unsigned slot);
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

/* bk_free_value ignores locals and immediates. bk_dup_value always returns a
 * registry root (or an immediate): the way a local outlives its scope. */
BK_API void bk_free_value(bk_ctx ctx, bk_value value);
BK_API bk_value bk_dup_value(bk_ctx ctx, bk_value value);

/* Local scopes. While a local scope is the innermost, every value-returning
 * call yields a local handle that dies when the scope closes, instead of a
 * registry root. A C callback's call is a local scope. Scopes nest strictly;
 * closing a scope closes the scopes opened inside it, and a callback's
 * unclosed scopes close when it returns. A scope holds at most 131,072 values;
 * past that, calls fail with BK_ERR_FULL. */
typedef uint32_t bk_scope;   /* 0 = none */
BK_API bk_scope bk_scope_open(bk_ctx ctx);
BK_API void     bk_scope_close(bk_ctx ctx, bk_scope scope);
/* Close `scope` and return `value` as a handle in the enclosing scope, or as an
 * owned registry root when no local scope encloses it. */
BK_API bk_value bk_scope_close_escape(bk_ctx ctx, bk_scope scope, bk_value value);
/* Copy any handle into the innermost local scope; with none, a registry root. */
BK_API bk_value bk_scope_local(bk_ctx ctx, bk_value value);
/* The innermost local scope, or 0. */
BK_API bk_scope bk_scope_current(bk_ctx ctx);
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
    const char *stack;   /* stack of the last thrown Error, context-owned; may be NULL */
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

/* The units of a string where they are stored. width 1 is Latin-1, one byte per
 * unit; width 2 is native-endian UTF-16. A string whose units are all at most
 * 0xFF always has width 1. ascii is nonzero when width is 1 and every unit is
 * below 0x80. The data is not NUL-terminated and is valid only until the next
 * call into the engine, which may collect or move the string. */
typedef struct bk_string_view {
    const void *data;
    size_t length; /* units */
    uint8_t width;
    uint8_t ascii;
} bk_string_view;
BK_API bk_status bk_string_view_get(bk_ctx ctx, bk_value value, bk_string_view *out);
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
/* Fails with BK_ERR_ENCODING and returns BK_EXCEPTION on invalid UTF-8. */
BK_API bk_value bk_new_string(bk_ctx ctx, const char *utf8, size_t length);
/* Each byte is the code point of the same value. */
BK_API bk_value bk_new_string_latin1(bk_ctx ctx, const uint8_t *chars, size_t length);
/* Lone surrogates are kept as given. */
BK_API bk_value bk_new_string_utf16(bk_ctx ctx, const uint16_t *units, size_t length);
/* Called once when an external string is freed, with the buffer it was created
 * over and its length in units. */
typedef void (*bk_string_release)(void *opaque, const void *data, size_t length);
/* A string over caller memory, read in place with no copy. The buffer must stay
 * unchanged until release runs, which may be after the context is destroyed;
 * release may be NULL for a buffer that never goes away. A UTF-16 buffer whose
 * units are all at most 0xFF, and an empty buffer, are copied and released
 * before the call returns. On failure returns BK_EXCEPTION and release is not
 * called. */
BK_API bk_value bk_new_external_string_latin1(bk_ctx ctx, const uint8_t *chars, size_t length,
                                              bk_string_release release, void *opaque);
BK_API bk_value bk_new_external_string_utf16(bk_ctx ctx, const uint16_t *units, size_t length,
                                             bk_string_release release, void *opaque);
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
/* An array of the object's own keys in [[OwnPropertyKeys]] order. With neither
 * BK_KEYS_STRINGS nor BK_KEYS_SYMBOLS both kinds are included.
 * BK_KEYS_ENUMERABLE_ONLY reads each key's descriptor, calling proxy traps. */
enum { BK_KEYS_OWN = 0, BK_KEYS_STRINGS = 1, BK_KEYS_SYMBOLS = 2,
       BK_KEYS_ENUMERABLE_ONLY = 4, BK_KEYS_SKIP_INDICES = 8 };
BK_API bk_value bk_get_own_property_keys(bk_ctx ctx, bk_value object, unsigned flags);

/* Atoms: property keys (strings, array indices, symbols) held by the runtime
 * and valid in every one of its contexts. One key has one atom while any
 * reference to it remains; each bk_new_atom, bk_new_atom_index,
 * bk_value_to_atom and bk_dup_atom adds a reference that bk_free_atom drops.
 * 0 is never an atom and reports failure. */
typedef uint32_t bk_atom;
BK_API bk_atom bk_new_atom(bk_ctx ctx, const char *utf8, size_t length);
BK_API bk_atom bk_new_atom_index(bk_ctx ctx, uint32_t index);
/* ToPropertyKey; may run JS and throw. */
BK_API bk_atom bk_value_to_atom(bk_ctx ctx, bk_value key);
/* The key as a string or symbol. */
BK_API bk_value bk_atom_to_value(bk_ctx ctx, bk_atom atom);
BK_API bk_atom bk_dup_atom(bk_ctx ctx, bk_atom atom);
BK_API void    bk_free_atom(bk_ctx ctx, bk_atom atom);
BK_API bk_value  bk_get_property_atom(bk_ctx ctx, bk_value object, bk_atom key);
BK_API bk_status bk_set_property_atom(bk_ctx ctx, bk_value object, bk_atom key, bk_value value);
BK_API bk_status bk_has_property_atom(bk_ctx ctx, bk_value object, bk_atom key, int *out);
BK_API bk_status bk_delete_property_atom(bk_ctx ctx, bk_value object, bk_atom key, int *out);

/* Property descriptors. A WRITABLE, ENUMERABLE or CONFIGURABLE bit counts only
 * with its HAS_ bit; a descriptor with neither value nor accessor bits is
 * generic. */
enum {
    BK_PROP_WRITABLE = 1, BK_PROP_ENUMERABLE = 2, BK_PROP_CONFIGURABLE = 4,
    BK_PROP_HAS_VALUE = 8, BK_PROP_HAS_GET = 16, BK_PROP_HAS_SET = 32,
    BK_PROP_HAS_WRITABLE = 64, BK_PROP_HAS_ENUMERABLE = 128, BK_PROP_HAS_CONFIGURABLE = 256
};
typedef struct {
    unsigned flags;
    bk_value value, get, set;   /* borrowed on input; locals or owned on output */
} bk_property_descriptor;
/* [[DefineOwnProperty]]: `ok` is 0 when the object refuses, as
 * Reflect.defineProperty returns false. Accessors must be functions or
 * BK_UNDEFINED. */
BK_API bk_status bk_define_property(bk_ctx ctx, bk_value object, bk_atom key,
                                    const bk_property_descriptor *desc, int *ok);
/* [[GetOwnProperty]], through Proxy traps. On a hit every HAS_ bit of the
 * descriptor's kind is set; handles not in use are BK_UNDEFINED. */
BK_API bk_status bk_get_own_property(bk_ctx ctx, bk_value object, bk_atom key,
                                     bk_property_descriptor *out, int *found);
BK_API bk_status bk_set_global_property(bk_ctx ctx, const char *name, size_t length, bk_value value);
/* Calls accept up to 65535 arguments; larger counts throw RangeError. */
BK_API bk_value bk_call(bk_ctx ctx, bk_value function, bk_value this_value, const bk_value *argv, unsigned argc);
/* [[Construct]]. new_target 0 means the constructor itself. */
BK_API bk_value bk_construct(bk_ctx ctx, bk_value constructor, const bk_value *argv,
                             unsigned argc, bk_value new_target);
/* proto is an object or BK_NULL. */
BK_API bk_value  bk_new_object_with_proto(bk_ctx ctx, bk_value proto);
/* [[GetPrototypeOf]], through proxy traps: an object or BK_NULL. */
BK_API bk_value  bk_get_prototype(bk_ctx ctx, bk_value object);
/* As Object.setPrototypeOf: a refused change throws a TypeError. */
BK_API bk_status bk_set_prototype(bk_ctx ctx, bk_value object, bk_value proto);
/* The instanceof operator, Symbol.hasInstance included. */
BK_API bk_status bk_instanceof(bk_ctx ctx, bk_value value, bk_value constructor, int *out);
/* === and Object.is. A handle that does not resolve compares unequal. */
BK_API int       bk_strict_equals(bk_ctx ctx, bk_value a, bk_value b);
BK_API int       bk_same_value(bk_ctx ctx, bk_value a, bk_value b);
/* Array.isArray, which sees through proxies: 1 or 0, or -1 after a throw
 * (a revoked proxy). */
BK_API int       bk_is_array(bk_ctx ctx, bk_value value);
/* LengthOfArrayLike: ToLength(object.length), which may run JS. */
BK_API bk_status bk_get_length(bk_ctx ctx, bk_value object, uint64_t *out);
/* JSON.parse of UTF-8 text, and JSON.stringify, which returns BK_UNDEFINED for
 * a value JSON cannot represent. */
BK_API bk_value  bk_json_parse(bk_ctx ctx, const char *utf8, size_t length);
BK_API bk_value  bk_json_stringify(bk_ctx ctx, bk_value value);

/* Arguments/this borrow the current call and must be duplicated to escape it.
 * Values the callback creates are locals of its call. It returns any live
 * handle (a local, an argument, an immediate or a registry root), which the
 * engine copies, or BK_EXCEPTION. bk_throw/error set the pending exception and
 * return BK_EXCEPTION. */
typedef bk_value (*bk_c_function)(bk_ctx ctx, bk_value this_value,
                                  unsigned argc, const bk_value *argv, void *opaque);
#define BK_CTOR 1u
/* Runs once with a C function's data when the function object is freed or the
 * runtime is destroyed. It may run in the middle of any engine call, so it must
 * not call the engine. */
typedef void (*bk_finalizer)(void *data, void *opaque);
/* The callback receives `data` as its `opaque`. With `finalize` NULL, `data`
 * is borrowed for the runtime's lifetime. Otherwise `finalize(data,
 * finalize_opaque)` runs exactly once, also when creation fails. */
BK_API bk_value bk_new_c_function(bk_ctx ctx, bk_c_function callback, const char *name,
                                  int arity, unsigned flags, void *data,
                                  bk_finalizer finalize, void *finalize_opaque);
typedef struct {
    const char *name;
    bk_c_function fn;
    int arity;
    unsigned flags;
    void *udata;
    bk_finalizer finalize;      /* as bk_new_c_function; NULL borrows udata */
    void *finalize_opaque;
} bk_fn_def;
#define BK_FN_END { NULL, NULL, 0, 0u, NULL, NULL, NULL }
/* Every entry's finalizer runs exactly once, also for entries a failed call
 * did not create. */
BK_API bk_status bk_set_function_list(bk_ctx ctx, bk_value target, const bk_fn_def *functions);
/* Install `fn` on `target`, or as a global when target is 0. */
BK_API bk_status bk_register_fn(bk_ctx ctx, bk_value target, const char *name,
                                bk_c_function fn, int arity, unsigned flags, void *opaque);
/* Call accessors (argc, arg, this, new.target) read the current call from any
 * depth of a callback and borrow it. Arguments past argc read as undefined;
 * outside a callback they return 0. */
BK_API unsigned bk_argc(bk_ctx ctx);
BK_API bk_value bk_arg(bk_ctx ctx, unsigned index);
BK_API bk_value bk_this(bk_ctx ctx);
BK_API bk_value bk_get_new_target(bk_ctx ctx);
BK_API int bk_is_constructor_call(bk_ctx ctx);
BK_API bk_value bk_throw_error(bk_ctx ctx, bk_error_kind kind, const char *message);
/* A new Error of `kind` carrying the UTF-8 `message` (NULL for none) and the
 * current stack. It is returned, not thrown. */
BK_API bk_value bk_new_error(bk_ctx ctx, bk_error_kind kind, const char *message);
/* Format a value for diagnostics without running JS: no getters, no Proxy
 * traps, no toString. Sizing follows bk_read_string, but a full buffer leaves
 * the context's diagnostics and pending exception untouched. */
BK_API bk_status bk_describe(bk_ctx ctx, bk_value value, char *buffer, size_t capacity, size_t *length);
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

#ifdef __cplusplus
}
#endif
#endif
