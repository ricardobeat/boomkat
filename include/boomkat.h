/*
 * boomkat.h — C99 embedding ABI for the boomkat JavaScript engine.
 *
 * Prefix rationale: "bk_" / "BK_" is the boomkat engine's symbol prefix.
 * duk_/DUK_ are Duktape's and stay out of new code; js_/JS_ collides with
 * QuickJS, whose sources are already vendored in this build. bk_ is short,
 * neutral, and collision-free against every vendored C symbol.
 *
 * DESIGN CONTRACT
 *   - Fully opaque. No engine struct is visible here. TVal is never exposed:
 *     it is 8 or 16 bytes depending on a compile-time feature, and all of its
 *     accessors are C3 macros with no linkable symbol.
 *   - Values are referenced by bk_value, an integer handle into a GC-rooted
 *     slot registry. A handle is NOT a pointer and must never be dereferenced.
 *   - Every call returns a status code or a nullable handle. Nothing aborts,
 *     panics, or longjmps across this boundary.
 *   - Several runtimes may be open at once and share nothing; values do not
 *     cross between them. A runtime must be driven from one thread at a time,
 *     which is not enforced (see bk_open).
 *
 * LINKING
 *   - The static archive is only safe when the final link is driven by a C
 *     toolchain (cc/clang/gcc). The C3 runtime locates its startup
 *     constructors by walking the init sections of the running image, and that
 *     walk needs the image header resolved correctly. Some foreign linkers
 *     defeat it: Zig's emits a second, bogus __mh_execute_header in
 *     __DATA,__bss, which the walk latches onto, faulting before main().
 *   - Link the SHARED library from any other toolchain (Zig, Rust, Go, ...).
 *     It is linked by c3c itself, so its constructors run under dyld/ld.so
 *     against the library's own header and resolve correctly.
 *
 * MEMORY / LIFETIME
 *   - Handles from bk_eval stay valid until bk_value_free or bk_close.
 *     They survive garbage collection: the registry is a GC root.
 *   - Handles leak if never freed. The registry grows on demand and reuses
 *     freed slots; its ceiling is 65535 simultaneously live handles, and
 *     exceeding that returns BK_ERR_FULL rather than misbehaving.
 *   - A freed handle is retired, not recycled blindly: reading one fails
 *     rather than resolving to whatever value later occupies that slot. A
 *     slot that exhausts its generation counter is withdrawn from reuse for
 *     the life of the runtime, so this holds for any number of cycles.
 *   - Strings are copied into caller-owned buffers. The ABI never hands out a
 *     pointer the caller must free, so there is no bk_free_string.
 *   - const char* from bk_last_error / bk_version point to storage owned by
 *     the runtime. Copy before the next call; do not free.
 */

#ifndef BOOMKAT_H
#define BOOMKAT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(BK_DLL)
#  define BK_API __declspec(dllimport)
#else
#  define BK_API
#endif

/* Opaque runtime handle. */
typedef void *bk_runtime;

/*
 * Opaque value handle. 0 is never a valid handle.
 *
 * 64 bits, not a pointer: the low half names a slot in the issuing runtime's
 * GC-rooted registry, and the high half carries that runtime's id, so a handle
 * used against the wrong runtime is rejected rather than silently resolving to
 * an unrelated value of the same shape.
 */
typedef uint64_t bk_value;
#define BK_INVALID_VALUE ((bk_value)0)

/*
 * Opaque per-call context handed to a host function. Valid only for the
 * duration of that call; never store one.
 */
typedef void *bk_call_ctx;

/* Status codes. 0 is success; all errors are negative. */
typedef enum {
    BK_OK           =  0,
    BK_ERR_NOMEM    = -1,  /* allocation failed */
    BK_ERR_SYNTAX   = -2,  /* compile failed; see bk_last_error */
    BK_ERR_THROW    = -3,  /* uncaught JS exception; see bk_last_error */
    BK_ERR_INTERNAL = -4,  /* engine fault with no JS error attached */
    BK_ERR_INVALID  = -5,  /* null/bad argument, or bad handle */
    BK_ERR_TYPE     = -6,  /* value is not of the requested type */
    BK_ERR_FULL     = -7,  /* buffer too small, or slot table exhausted */
    BK_ERR_INTERRUPT = -8  /* aborted by the interrupt handler */
} bk_status;

/* Value types as reported by bk_type_of. */
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

/* ---------------------------------------------------------------- lifecycle */

/*
 * Create the runtime and store it in *out_rt.
 *
 * Multiple runtimes may exist in one process. Each is fully independent
 * (heaps, globals, string tables); the compiler error state lives on the
 * per-compilation lexer, so parallel compiles on separate threads do not
 * share a buffer. Returns BK_OK, BK_ERR_NOMEM, or BK_ERR_INVALID.
 */
BK_API int bk_open(bk_runtime *out_rt);

/*
 * Destroy the runtime and everything it owns. All outstanding handles become
 * invalid. Safe to call with NULL. Teardown order is handled internally.
 */
BK_API void bk_close(bk_runtime rt);

/* Static version string, "MAJOR.MINOR.PATCH". Never NULL. */
BK_API const char *bk_version(void);

/* --------------------------------------------------------------------- eval */

/*
 * Compile and run `len` bytes of UTF-8 source, evaluated for its completion
 * value (so "40 + 2" yields 42, matching eval() semantics).
 *
 * On BK_OK, if out_val is non-NULL it receives a handle to the result, which
 * the caller owns and must release with bk_value_free. Pass NULL for out_val
 * to run purely for side effects.
 *
 * On failure *out_val is set to BK_INVALID_VALUE and bk_last_error carries
 * the detail. Microtasks are drained automatically before returning.
 *
 * Returns BK_OK, BK_ERR_SYNTAX, BK_ERR_THROW, BK_ERR_INTERNAL,
 * BK_ERR_INVALID, BK_ERR_FULL, or BK_ERR_INTERRUPT.
 */
BK_API int bk_eval(bk_runtime rt, const char *src, size_t len,
                   bk_value *out_val);

/*
 * Like bk_eval, with `name` (UTF-8, `name_len` bytes) recorded as the script
 * name for error reporting. The name is copied into runtime storage. NULL
 * `name` behaves like an empty name. Returns the same statuses as bk_eval.
 */
BK_API int bk_eval_with_name(bk_runtime rt, const char *src, size_t len,
                             const char *name, size_t name_len,
                             bk_value *out_val);

/* Release a handle. Safe with 0 or an already-freed handle. */
BK_API void bk_value_free(bk_runtime rt, bk_value v);

/* ------------------------------------------------------------------ readers */

/*
 * Readers come in two tiers, and which one you want follows from what you hold.
 *
 * Outside a callback you hold a bk_runtime: use bk_get_number and friends.
 * Inside a host function you hold a bk_call_ctx and no runtime: use the
 * bk_ctx_* forms. Only the context tier can resolve the handles bk_arg,
 * bk_this and bk_new_target hand out, because those name a slot in the call's
 * scope rather than in the runtime's registry.
 *
 * Neither tier accepts NULL. A value handle is an index into one runtime's
 * registry, so with more than one runtime open there is no "the runtime" to
 * guess: resolving a handle against the wrong one would answer with an
 * unrelated value rather than fail. bk_ctx_runtime(ctx) gets you the runtime
 * when you need it, mirroring QuickJS's JS_GetRuntime.
 */

/*
 * Type of a value. An invalid or freed handle reports BK_TYPE_UNDEFINED, so
 * this never fails and needs no status code.
 */
BK_API int bk_type_of(bk_runtime rt, bk_value v);
BK_API int bk_ctx_type_of(bk_call_ctx ctx, bk_value v);

/*
 * Read a number. Accepts both internal numeric representations (double and
 * the 47-bit fast integer), so any JS number succeeds.
 * Returns BK_OK, BK_ERR_TYPE, or BK_ERR_INVALID.
 */
BK_API int bk_get_number(bk_runtime rt, bk_value v, double *out);
BK_API int bk_ctx_get_number(bk_call_ctx ctx, bk_value v, double *out);

/*
 * Read a boolean into *out as 0 or 1. Strict: does not coerce.
 * Returns BK_OK, BK_ERR_TYPE, or BK_ERR_INVALID.
 */
BK_API int bk_get_bool(bk_runtime rt, bk_value v, int *out);
BK_API int bk_ctx_get_bool(bk_call_ctx ctx, bk_value v, int *out);

/*
 * Copy a string out as NUL-terminated UTF-8. Strict: does not coerce, so call
 * String(x) in JS first if you want stringification.
 *
 * Two-call protocol. Pass buf == NULL to measure: *out_len receives the byte
 * length excluding the NUL, and the call returns BK_OK. Then pass a buffer of
 * at least *out_len + 1.
 *
 * The engine stores text as CESU-8; this converts to standard UTF-8, so astral
 * characters emerge as proper 4-byte sequences rather than surrogate halves.
 *
 * Returns BK_OK, BK_ERR_FULL (cap too small), BK_ERR_TYPE, or
 * BK_ERR_INVALID.
 */
BK_API int bk_get_string(bk_runtime rt, bk_value v, char *buf, size_t cap,
                         size_t *out_len);
BK_API int bk_ctx_get_string(bk_call_ctx ctx, bk_value v, char *buf,
                             size_t cap, size_t *out_len);

/*
 * The runtime that owns a callback's context, for a host that needs to persist
 * a value or evaluate from inside a call. Mirrors JS_GetRuntime(ctx).
 */
BK_API bk_runtime bk_ctx_runtime(bk_call_ctx ctx);

/* ------------------------------------------------------- errors / microtasks */

/*
 * Message for the most recent failure on this runtime, as a NUL-terminated
 * UTF-8 string owned by the runtime. Never NULL; empty when no error. Valid
 * until the next bk_* call. Formatted without re-entering the VM, so a
 * throwing user toString cannot recurse here.
 *
 * Every bk_ call that can fail sets this before returning a non-zero status,
 * including the readers (bk_get_number / bk_get_bool / bk_get_string), so a
 * host may log it unconditionally on failure. Those readers also clear it on
 * entry, so a message never survives from an unrelated earlier call.
 *
 * A NULL runtime, NULL context or NULL out-parameter returns BK_ERR_INVALID
 * with no runtime to record the message in.
 *
 * For a thrown Error the text is "Name: message" ("TypeError: x is not a
 * function"), which lets a host map it onto its own exception classes; `name`
 * is read off the prototype chain. A thrown primitive formats as its value, so
 * `throw 42` reports "42" and `throw null` reports "null". A thrown object with
 * neither `name` nor `message` reports "uncaught exception (object)". The
 * prototype walk stops at a Proxy and ignores accessors rather than invoking a
 * trap or getter, since this runs on the unwind path.
 */
BK_API const char *bk_last_error(bk_runtime rt);

/* Status code matching bk_last_error, or BK_OK if none. */
BK_API int bk_last_error_code(bk_runtime rt);

/* Kind and location of the most recent failure; see bk_last_error_info. */
typedef struct {
    int   code;          /* BK_ERR_* of the failure, BK_OK if none */
    int   line;          /* 1-based line, 0 if unknown */
    int   col;           /* 1-based column, 0 if unknown */
    const char *script_name; /* name from bk_eval_with_name, or NULL */
} bk_error_info;

/*
 * Fill *out with the details of the most recent failure on this runtime.
 * `script_name` points to runtime-owned storage with the same lifetime as
 * bk_last_error. Returns BK_OK, or BK_ERR_INVALID for a NULL argument.
 */
BK_API int bk_last_error_info(bk_runtime rt, bk_error_info *out);

/*
 * Run pending promise jobs. bk_eval already drains before returning; call
 * this after resolving promises from host code. Re-entrancy-guarded.
 *
 * Returns BK_OK, or BK_ERR_INTERRUPT when an interrupt fired inside a job
 * (the drain aborts; the remaining queue is dropped). Existing callers that
 * ignore the return keep compiling.
 */
BK_API int bk_drain_microtasks(bk_runtime rt);

/*
 * Host callback polled by the VM at safepoints (backward branches and call
 * restarts). Return non-zero to abort the running script as BK_ERR_INTERRUPT.
 *
 * Runs on the engine thread. It must not call any bk_* function: no eval,
 * no call, no value access. A host that wants to interrupt from another
 * thread stores a flag in `opaque` (with its own synchronisation) and the
 * handler returns it; the engine never dereferences `opaque`.
 */
typedef int (*bk_interrupt_handler)(bk_runtime rt, void *opaque);

/*
 * Install or replace the interrupt handler; pass NULL for `cb` to clear it.
 * Never fails; a NULL runtime is a no-op. The abort is uncatchable: a JS
 * try/catch cannot intercept it, so script cannot swallow the abort and
 * resume looping, but finally blocks still run during the unwind. After the
 * abort the runtime stays usable; the next eval starts with a fresh poll
 * budget.
 */
BK_API void bk_set_interrupt_handler(bk_runtime rt,
                                     bk_interrupt_handler cb,
                                     void *opaque);

/* ----------------------------------------------------------- host functions */

/*
 * A host function is a C callback JS can invoke by name.
 *
 * Engine-side, a host function is an ordinary JS function object whose
 * internal dispatch index lives in a reserved range, so it behaves like a
 * built-in everywhere: plain calls, methods, .call/.apply/.bind, accessors,
 * `new`, `super()`, and callbacks passed to built-ins such as Array.sort.
 *
 * The callback receives an opaque context. Values reached through it
 * (bk_arg, bk_this, bk_new_target) are SCOPE handles, valid only until the
 * callback returns. To keep one past that, promote it with bk_value_persist,
 * which yields a runtime-owned handle the caller must bk_value_free. Scope
 * handles passed to bk_value_free are ignored rather than treated as an
 * error.
 *
 * Errors never unwind through C: bk_throw_error and bk_throw record the
 * throw and return normally, and the callback must also return normally. A
 * recorded throw beats any return value set in the same callback.
 */
typedef void (*bk_host_fn)(bk_call_ctx ctx, void *udata);

/* Error kinds for bk_throw_error. */
typedef enum {
    BK_ERROR           = 0,
    BK_ERROR_TYPE      = 1,
    BK_ERROR_RANGE     = 2,
    BK_ERROR_REFERENCE = 3,
    BK_ERROR_SYNTAX    = 4
} bk_error_kind;

/*
 * Bind `cfn` as a global function named `name` (`name_len` bytes, UTF-8).
 *
 * `udata` is passed back to every invocation untouched and is never
 * dereferenced by the engine. `arity` becomes the function's .length, and
 * `constructable` non-zero allows `new`; a zero value makes `new fn()` throw a
 * TypeError, matching ES2015 §10.3 where built-ins construct only when
 * specified.
 *
 * Registration is permanent for the runtime's lifetime. Returns BK_OK,
 * BK_ERR_INVALID, BK_ERR_NOMEM, or BK_ERR_INTERNAL.
 */
BK_API int bk_register_fn(bk_runtime rt, const char *name, size_t name_len,
                          bk_host_fn cfn, void *udata,
                          int arity, int constructable);

/* Number of arguments this call was made with. */
BK_API unsigned int bk_argc(bk_call_ctx ctx);

/*
 * Handle to argument `i`. An index at or past bk_argc yields a handle to
 * undefined rather than an invalid handle, matching JS semantics for missing
 * arguments.
 */
BK_API bk_value bk_arg(bk_call_ctx ctx, unsigned int i);

/* The `this` receiver. Strict semantics: an undefined receiver stays undefined. */
BK_API bk_value bk_this(bk_call_ctx ctx);

/* new.target, or a handle to undefined on a plain call. */
BK_API bk_value bk_new_target(bk_call_ctx ctx);

/* Non-zero when invoked through `new` or `super()`. */
BK_API int bk_is_construct(bk_call_ctx ctx);

/*
 * Set the return value. A callback that sets none yields undefined.
 *
 * On a constructor call the engine has already created the instance and
 * bk_this sees it; returning nothing keeps that object, and returning an
 * object replaces it, per ES2015 §9.2.2.
 */
BK_API void bk_return(bk_call_ctx ctx, bk_value v);
BK_API void bk_return_number(bk_call_ctx ctx, double d);
BK_API void bk_return_bool(bk_call_ctx ctx, int b);
BK_API void bk_return_null(bk_call_ctx ctx);

/* Return a fresh JS string built from `len` bytes of UTF-8. */
BK_API void bk_return_string(bk_call_ctx ctx, const char *utf8, size_t len);

/* Record a throw of a fresh Error of `kind` carrying NUL-terminated `msg`. */
BK_API void bk_throw_error(bk_call_ctx ctx, int kind, const char *msg);

/* Record a throw of an arbitrary value. */
BK_API void bk_throw(bk_call_ctx ctx, bk_value v);

/*
 * Copy a value into the runtime's global registry and return a handle that
 * outlives the callback. The caller owns it and must bk_value_free it. This
 * is the only supported way to retain a value past the call.
 */
BK_API bk_value bk_value_persist(bk_call_ctx ctx, bk_value v);

/*
 * Call a JS function from inside a host callback.
 *
 * `argv` is an array of `argc` handles; pass NULL/0 for no arguments. Pass 0
 * for `this_val` to call with undefined. On BK_OK, *out_val (when non-NULL)
 * receives a runtime-owned handle the caller must bk_value_free.
 *
 * If the callee throws, the exception is recorded on this callback's context
 * and BK_ERR_THROW is returned; the host should return promptly and let the
 * engine propagate it. Calling a non-function records a TypeError.
 *
 * Host recursion is bounded: a host -> JS -> host chain that nests too deeply
 * throws a RangeError rather than exhausting the native stack.
 */
BK_API int bk_call(bk_call_ctx ctx, bk_value func, const bk_value *argv,
                   unsigned int argc, bk_value this_val, bk_value *out_val);

/* ------------------------------------------------- construction / object graph */

/*
 * Value and object constructors for hosts outside a callback, mirroring the
 * bk_return_* helpers. A returned handle is caller-owned and must be
 * released with bk_value_free, like a bk_eval result.
 *
 * All return BK_OK, BK_ERR_INVALID (null handle), BK_ERR_NOMEM (heap), or
 * BK_ERR_FULL (slot table exhausted).
 */
BK_API int bk_new_number(bk_runtime rt, double d, bk_value *out);
BK_API int bk_new_bool(bk_runtime rt, int b, bk_value *out);
BK_API int bk_new_null(bk_runtime rt, bk_value *out);
BK_API int bk_new_undefined(bk_runtime rt, bk_value *out);
/* Fresh JS string from `len` bytes of UTF-8. */
BK_API int bk_new_string(bk_runtime rt, const char *utf8, size_t len,
                         bk_value *out);
BK_API int bk_new_object(bk_runtime rt, bk_value *out);
BK_API int bk_new_array(bk_runtime rt, bk_value *out);
/* Fresh array whose elements are the first `n` of `elems`; copies them in. */
BK_API int bk_new_array_from(bk_runtime rt, const bk_value *elems,
                             unsigned int n, bk_value *out);
/* Handle to the global object (globalThis). Caller owns it. */
BK_API int bk_get_global(bk_runtime rt, bk_value *out);

/*
 * Read `key` from `obj`, following the prototype chain. A missing property
 * yields BK_OK with *out set to a handle of undefined, matching JS. A getter
 * or Proxy trap that throws returns BK_ERR_THROW (or BK_ERR_INTERRUPT).
 */
BK_API int bk_get_prop(bk_runtime rt, bk_value obj,
                       const char *key, size_t key_len, bk_value *out);
BK_API int bk_get_prop_index(bk_runtime rt, bk_value obj,
                             unsigned int idx, bk_value *out);

/*
 * Write `val` with full Set semantics (own or inherited writable
 * data/accessor). The value is copied in; the handle stays caller-owned. A
 * setter or a strict-mode write failure throws, reported as BK_ERR_THROW.
 */
BK_API int bk_set_prop(bk_runtime rt, bk_value obj,
                       const char *key, size_t key_len, bk_value val);
BK_API int bk_set_prop_index(bk_runtime rt, bk_value obj,
                             unsigned int idx, bk_value val);

/* `key in obj`, chain included. Sets *out to 0 or 1. */
BK_API int bk_has_prop(bk_runtime rt, bk_value obj,
                       const char *key, size_t key_len, int *out);

/*
 * `delete obj.key`. Sets *out to 1 if deleted, 0 if the property was not an
 * own property. Deleting a non-configurable property throws (strict engine),
 * reported as BK_ERR_THROW.
 */
BK_API int bk_delete_prop(bk_runtime rt, bk_value obj,
                          const char *key, size_t key_len, int *out);

/* Fresh array of `obj`'s own string property names (enumerable and not;
 * symbol keys deferred). Walk it with bk_get_prop_index. */
BK_API int bk_own_prop_names(bk_runtime rt, bk_value obj, bk_value *out);

/*
 * Call a JS function from outside a callback. `argv`/`argc` (NULL/0 for none),
 * `this_val` (0 for undefined). On BK_OK, *out_val (when non-NULL) receives a
 * caller-owned handle. A thrown callee returns BK_ERR_THROW (or
 * BK_ERR_INTERRUPT for an interrupt); the exception is recorded on the
 * runtime, not unwound through C. Calling a non-function records a TypeError.
 * If the callee is a host function it gets a fresh call context.
 */
BK_API int bk_call_rt(bk_runtime rt, bk_value func, const bk_value *argv,
                      unsigned int argc, bk_value this_val,
                      bk_value *out_val);

#ifdef __cplusplus
}
#endif

#endif /* BOOMKAT_H */
