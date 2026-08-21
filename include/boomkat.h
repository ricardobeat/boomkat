/*
 * boomkat.h -- C99 embedding API for the boomkat JavaScript engine.
 *
 * Hello world, in full:
 *
 *     #include <stdio.h>
 *     #include <boomkat.h>
 *
 *     int main(void) {
 *         bk_ctx js = bk_open();
 *         bk_value v = bk_eval_str(js, "[1,2,3].map(n => n*n).join()");
 *         if (!v) { fprintf(stderr, "%s\n", bk_error(js)); return 1; }
 *         printf("%s\n", bk_cstr(js, v, NULL));
 *         bk_free(js, v);
 *         bk_close(js);
 *     }
 *
 *     cc -std=c99 -Iinclude hello.c out/boomkat.a -o hello   # -lm -ldl on Linux
 *
 * DESIGN CONTRACT
 *
 *   - One context type. `bk_ctx` is both "the runtime" and "this call": the
 *     same reader, constructor and property call works at top level and inside
 *     a host function. There is no second tier of entry points.
 *
 *   - Values are handles, not pointers. A `bk_value` is an integer naming a
 *     slot in the issuing context's GC-rooted registry. Never dereference one.
 *     It carries the id of the runtime that issued it, so using it against a
 *     different runtime is an error rather than a wrong answer.
 *
 *   - Failure is in the return value. Calls that produce a value return the
 *     handle, and `0` (BK_INVALID_VALUE) means failure; calls that produce no
 *     value return a `bk_status`. Ask `bk_error_code` / `bk_error` for the
 *     detail. Nothing aborts, panics, or longjmps across this boundary.
 *
 *   - Nothing here can be redeclared wrongly. The status codes, type codes and
 *     the inline helpers below are the whole surface; a binding for another
 *     language needs no private copy of any constant.
 *
 * MEMORY / LIFETIME
 *
 *   - A handle from bk_eval and friends is owned by the caller and lives until
 *     bk_free or bk_close. It survives garbage collection: the registry is a
 *     GC root. Handles leak if never freed.
 *
 *   - Handles inside a host callback (bk_arg, bk_this, bk_new_target) are
 *     SCOPE handles, valid only until that callback returns. bk_persist
 *     promotes one to an owned handle. Passing a scope handle to bk_free is
 *     ignored, not an error.
 *
 *   - A freed handle is retired, not recycled blindly: reading one fails
 *     rather than resolving to whatever value later occupies that slot.
 *
 *   - bk_cstr returns storage owned by the context, valid until the fourth
 *     following bk_cstr call. bk_strdup returns memory the caller frees.
 *     bk_error and bk_version point to context- or static storage; copy before
 *     the next call, do not free.
 *
 * THREADS
 *
 *   - Several contexts may be open at once and share nothing. One context must
 *     be driven from one thread at a time, which is not enforced.
 *
 * LINKING
 *
 *   - The static archive is only safe when the final link is driven by a C
 *     toolchain (cc/clang/gcc). The C3 runtime locates its startup
 *     constructors by walking the init sections of the running image, and some
 *     foreign linkers defeat that walk: Zig's emits a second, bogus
 *     __mh_execute_header in __DATA,__bss, which the walk latches onto,
 *     faulting before main(). Link the SHARED library from any other toolchain
 *     (Zig, Rust, Go, ...); it is linked by c3c itself, so its constructors
 *     resolve against the library's own header.
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
#  define BK_API __declspec(dllimport)
#else
#  define BK_API
#endif

/*
 * A runtime, and inside a host function also the call in progress. Opaque;
 * never dereference it. A callback's context is valid only for that call.
 */
typedef struct bk_ctx_s *bk_ctx;

/*
 * Opaque value handle. 0 is never valid.
 *
 * 64 bits, not a pointer: the low half names a slot in the issuing runtime's
 * GC-rooted registry, and the top 16 bits carry that runtime's id, so a handle
 * used against the wrong runtime is refused rather than silently resolving to
 * an unrelated value of the same shape.
 */
typedef uint64_t bk_value;
#define BK_INVALID_VALUE ((bk_value)0)

/* Status codes. 0 is success; all failures are negative. */
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
    BK_ERR_INTERRUPT = -8   /* aborted by the interrupt handler */
} bk_status;
/* END GENERATED status */

/* Value types as reported by bk_type. */
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

/* Error constructors for bk_throw_error. */
/* BEGIN GENERATED errkind (scripts/gen_abi_header.py) */
typedef enum {
    BK_ERROR           = 0,
    BK_ERROR_TYPE      = 1,
    BK_ERROR_RANGE     = 2,
    BK_ERROR_REFERENCE = 3,
    BK_ERROR_SYNTAX    = 4
} bk_error_kind;
/* END GENERATED errkind */

/* ---------------------------------------------------------------- lifecycle */

/*
 * Open a runtime. Returns NULL if it could not be created; there is no error
 * context to consult in that case, since the context is what failed.
 *
 * Several may be open at once. Each is fully independent: heaps, globals,
 * interned strings. Values do not cross between them.
 */
BK_API bk_ctx bk_open(void);

/*
 * Destroy the runtime and everything it owns. All outstanding handles become
 * invalid. Safe with NULL. Do not call on a callback's context.
 */
BK_API void bk_close(bk_ctx ctx);

/* Static version string, "MAJOR.MINOR.PATCH". Never NULL. */
BK_API const char *bk_version(void);

/* --------------------------------------------------------------------- eval */

/*
 * Compile and run `len` bytes of UTF-8 source, evaluated for its completion
 * value, so "40 + 2" yields 42 (eval() semantics, not script semantics).
 *
 * Returns an owned handle, or 0 on failure with the detail in bk_error.
 * Microtasks are drained before returning.
 */
BK_API bk_value bk_eval(bk_ctx ctx, const char *src, size_t len);

/*
 * As bk_eval, with `name` recorded as the script name for error reporting.
 * `name` is copied. NULL behaves like "<eval>".
 */
BK_API bk_value bk_eval_named(bk_ctx ctx, const char *src, size_t len,
                              const char *name, size_t name_len);

/*
 * Run pending promise jobs. bk_eval already drains; call this after resolving
 * promises from host code. Re-entrancy-guarded.
 *
 * Returns BK_OK, or BK_ERR_INTERRUPT when an interrupt fired inside a job (the
 * drain aborts and the remaining queue is dropped).
 */
BK_API bk_status bk_drain(bk_ctx ctx);

/* ---------------------------------------------------------- value lifetime */

/* Release an owned handle. Safe with 0, a scope handle, or a freed handle. */
BK_API void bk_free(bk_ctx ctx, bk_value v);

/*
 * Copy a value into the runtime's registry and return a handle that outlives
 * the current callback. This is the only way to keep an argument past the call
 * that supplied it. The result is owned by the caller.
 */
BK_API bk_value bk_persist(bk_ctx ctx, bk_value v);

/* ------------------------------------------------------------------- errors */

/*
 * Message for the most recent failure, NUL-terminated UTF-8 owned by the
 * context. Never NULL; empty when there was none. Valid until the next bk_*
 * call. Formatted without re-entering the VM, so a throwing user toString
 * cannot recurse here.
 *
 * A thrown Error reads as "Name: message" ("TypeError: x is not a function"),
 * which lets a host map it onto its own exception classes. A thrown primitive
 * formats as its value, so `throw 42` reports "42". The prototype walk stops
 * at a Proxy and ignores accessors rather than invoking a trap or getter,
 * since this runs on the unwind path.
 */
BK_API const char *bk_error(bk_ctx ctx);

/* Status code matching bk_error, or BK_OK if there was no failure. */
BK_API bk_status bk_error_code(bk_ctx ctx);

/* Kind and location of the most recent failure. */
typedef struct {
    int         code;        /* BK_ERR_* of the failure, BK_OK if none */
    int         line;        /* 1-based line, 0 if unknown */
    int         col;         /* 1-based column, 0 if unknown */
    const char *script_name; /* name from bk_eval_named, or NULL */
} bk_error_info;

/*
 * Fill *out with the details of the most recent failure. `script_name` has the
 * same lifetime as bk_error. Returns BK_OK, or BK_ERR_INVALID for a NULL
 * argument.
 */
BK_API bk_status bk_error_info_of(bk_ctx ctx, bk_error_info *out);

/* Names for logging. Never NULL, even for an unknown code. */
BK_API const char *bk_status_str(bk_status status);
BK_API const char *bk_type_str(bk_type type);

/* ---------------------------------------------------------- reading values */

/*
 * Type of a value. An invalid or freed handle reports BK_TYPE_UNDEFINED, so
 * this never fails.
 */
BK_API bk_type bk_type_of(bk_ctx ctx, bk_value v);

/*
 * Strict readers. They do not coerce: a string is not a number here. Return
 * BK_OK, BK_ERR_TYPE, or BK_ERR_INVALID, and leave a message behind on
 * failure, so a host may log bk_error unconditionally.
 */
BK_API bk_status bk_read_number(bk_ctx ctx, bk_value v, double *out);
BK_API bk_status bk_read_bool(bk_ctx ctx, bk_value v, int *out);

/*
 * Copy a string value out as NUL-terminated UTF-8 without allocating.
 *
 * Two-call protocol: pass buf == NULL to measure (*out_len receives the byte
 * length excluding the NUL), then pass a buffer of at least *out_len + 1. If
 * `cap` is too small the call returns BK_ERR_FULL and writes the required
 * length, so a failed fill tells you how big to retry.
 *
 * Strict, like the other readers. For "give me this value as text whatever it
 * is", use bk_cstr.
 *
 * The engine stores text as CESU-8; this converts to standard UTF-8, so astral
 * characters emerge as proper 4-byte sequences rather than surrogate halves.
 */
BK_API bk_status bk_read_string(bk_ctx ctx, bk_value v, char *buf, size_t cap,
                                size_t *out_len);

/* ------------------------------------------------------------ coercion tier */

/*
 * The ES abstract operations, for hosts that want JS semantics rather than a
 * type check. Each may run user code (valueOf/toString) and therefore throw;
 * on a throw they report the failure through bk_error_code and return the
 * zero value shown.
 */
BK_API double   bk_to_number(bk_ctx ctx, bk_value v);   /* NaN on throw */
BK_API int      bk_to_bool(bk_ctx ctx, bk_value v);     /* 0 on throw; never throws in practice */
BK_API bk_value bk_to_string(bk_ctx ctx, bk_value v);   /* 0 on throw; owned handle */

/*
 * Any value as text, the way String(v) would render it.
 *
 * The returned pointer is owned by the context and stays valid until the
 * fourth following bk_cstr call on it, so several results can be live in one
 * printf. Returns NULL only if the conversion threw. `out_len` may be NULL.
 *
 * This is the short path: `printf("%s", bk_cstr(js, v, NULL))` needs no
 * buffer, no size query and no free. When you need to own the memory, use
 * bk_strdup; when you must not allocate at all, use bk_read_string.
 */
BK_API const char *bk_cstr(bk_ctx ctx, bk_value v, size_t *out_len);

/*
 * As bk_cstr, but the caller owns the result and frees it with free().
 * Returns NULL if the conversion threw or allocation failed.
 */
BK_API char *bk_strdup(bk_ctx ctx, bk_value v, size_t *out_len);

/* ------------------------------------------------------ building values */

/*
 * Constructors. Each returns an owned handle, or 0 on failure with the detail
 * in bk_error.
 */
BK_API bk_value bk_number(bk_ctx ctx, double d);
BK_API bk_value bk_bool(bk_ctx ctx, int b);
BK_API bk_value bk_null(bk_ctx ctx);
BK_API bk_value bk_undefined(bk_ctx ctx);
BK_API bk_value bk_string(bk_ctx ctx, const char *utf8, size_t len);
BK_API bk_value bk_object(bk_ctx ctx);
BK_API bk_value bk_array(bk_ctx ctx);
/* Array of the first `n` of `elems`, copied in; the caller keeps its handles. */
BK_API bk_value bk_array_of(bk_ctx ctx, const bk_value *elems, unsigned int n);
/* globalThis. */
BK_API bk_value bk_global(bk_ctx ctx);

/* --------------------------------------------------------------- properties */

/*
 * Read `key` off `obj`, following the prototype chain. A missing property
 * yields a handle to undefined, matching JS. Returns 0 if `obj` is not an
 * object, or if a getter or Proxy trap threw.
 */
BK_API bk_value bk_get(bk_ctx ctx, bk_value obj, const char *key, size_t key_len);
BK_API bk_value bk_get_index(bk_ctx ctx, bk_value obj, unsigned int idx);

/*
 * Write with full Set semantics (own or inherited, data or accessor). The
 * value is copied in; the handle stays owned by the caller. A setter that
 * throws, or a failed strict-mode write, reports BK_ERR_THROW.
 */
BK_API bk_status bk_set(bk_ctx ctx, bk_value obj, const char *key, size_t key_len,
                        bk_value val);
BK_API bk_status bk_set_index(bk_ctx ctx, bk_value obj, unsigned int idx, bk_value val);

/* `key in obj`, chain included. Sets *out to 0 or 1. */
BK_API bk_status bk_has(bk_ctx ctx, bk_value obj, const char *key, size_t key_len,
                        int *out);

/*
 * `delete obj.key`. Sets *out to 1 if deleted, 0 if there was no own property.
 * Deleting a non-configurable property throws, as it must in a strict engine.
 */
BK_API bk_status bk_delete(bk_ctx ctx, bk_value obj, const char *key, size_t key_len,
                           int *out);

/*
 * Array of `obj`'s own string property names, enumerable and not (symbol keys
 * are skipped). Walk it with bk_get_index.
 */
BK_API bk_value bk_keys(bk_ctx ctx, bk_value obj);

/* -------------------------------------------------------------------- calls */

/*
 * Call a JS function. Pass 0 for `this_val` to call with undefined, and
 * NULL/0 for no arguments. Returns an owned handle, or 0 on failure.
 *
 * Works at top level and inside a host callback alike. If the callee throws
 * from inside a callback, the exception is staged on that call: return
 * promptly and let the engine propagate it. Host recursion is bounded, so a
 * host -> JS -> host chain that nests too deeply gets a RangeError rather than
 * exhausting the native stack.
 */
BK_API bk_value bk_call(bk_ctx ctx, bk_value fn, bk_value this_val,
                        const bk_value *argv, unsigned int argc);

/* ----------------------------------------------------------- host functions */

/*
 * A host function is a C callback JS can invoke.
 *
 * Engine-side it is an ordinary JS function object, so it behaves like a
 * built-in everywhere: plain calls, methods, .call/.apply/.bind, accessors,
 * `new`, `super()`, and callbacks passed to Array.sort and friends.
 *
 * `ctx` is the call. Every reader, constructor and property function in this
 * header accepts it. It is valid only for the body of the callback.
 *
 * Errors never unwind through C: bk_throw and bk_throw_error record the throw
 * and return normally, and the callback must return normally too. A recorded
 * throw beats any value set with bk_return.
 */
typedef void (*bk_host_fn)(bk_ctx ctx, void *udata);

/* Flags for bk_fn_def.flags. */
#define BK_CTOR 1u   /* `new fn()` is allowed; without it, it throws a TypeError */

/*
 * One entry in a registration table. `arity` becomes the function's .length
 * and is advisory -- JS may call with any number of arguments, so consult
 * bk_argc. `udata` is handed back untouched on every call and is never
 * dereferenced by the engine.
 */
typedef struct {
    const char  *name;
    bk_host_fn   fn;
    int          arity;
    unsigned int flags;
    void        *udata;
} bk_fn_def;

#define BK_FN_END { NULL, NULL, 0, 0u, NULL }

/*
 * Install a whole table of functions in one call. The table ends at the first
 * entry with a NULL name, so terminate it with BK_FN_END.
 *
 *     static const bk_fn_def api[] = {
 *         { "log",   host_log,   1, 0u,      NULL },
 *         { "Point", host_point, 2, BK_CTOR, NULL },
 *         BK_FN_END
 *     };
 *     bk_register(js, 0, api);
 *
 * `target` is the object to install on; pass 0 for globalThis. Registration
 * lasts for the runtime's lifetime and cannot be undone.
 *
 * Returns BK_OK, or the failure of the first entry that could not be
 * installed; the entries before it stay installed.
 */
BK_API bk_status bk_register(bk_ctx ctx, bk_value target, const bk_fn_def *defs);

/* Bind `name` to `v` as a global. The value is copied in. */
BK_API bk_status bk_set_global(bk_ctx ctx, const char *name, size_t name_len,
                               bk_value v);

/* ------------------------------------------------------ inside a callback */

/* Number of arguments this call was made with. */
BK_API unsigned int bk_argc(bk_ctx ctx);

/*
 * Argument `i` as a scope handle. An index at or past bk_argc yields undefined
 * rather than an error, matching JS and sparing every host an arity check.
 */
BK_API bk_value bk_arg(bk_ctx ctx, unsigned int i);

/* The `this` receiver. Strict semantics: an undefined receiver stays undefined. */
BK_API bk_value bk_this(bk_ctx ctx);

/* new.target, or undefined on a plain call. */
BK_API bk_value bk_new_target(bk_ctx ctx);

/* Non-zero when invoked through `new` or `super()`. */
BK_API int bk_is_construct(bk_ctx ctx);

/*
 * Set the return value. A callback that sets none returns undefined.
 *
 * On a constructor call the engine has already created the instance and
 * bk_this sees it; returning nothing keeps that object, and returning an
 * object replaces it.
 */
BK_API void bk_return(bk_ctx ctx, bk_value v);

/* Record a throw of a fresh Error of `kind` carrying NUL-terminated `msg`. */
BK_API void bk_throw_error(bk_ctx ctx, bk_error_kind kind, const char *msg);

/* Record a throw of an arbitrary value. */
BK_API void bk_throw(bk_ctx ctx, bk_value v);

/* ---------------------------------------------------------------- interrupt */

/*
 * Polled by the VM at safepoints (backward branches and call restarts). Return
 * non-zero to abort the running script as BK_ERR_INTERRUPT.
 *
 * Runs on the engine thread and must not call any bk_* function. A host that
 * wants to interrupt from another thread stores a flag in `opaque` (with its
 * own synchronisation) and returns it; the engine never dereferences `opaque`.
 */
typedef int (*bk_interrupt_fn)(bk_ctx ctx, void *opaque);

/*
 * Install, replace (or with NULL, clear) the interrupt handler. The abort is
 * uncatchable, so script cannot swallow it and resume looping, but finally
 * blocks still run during the unwind. Afterwards the runtime stays usable and
 * the next eval starts with a fresh poll budget.
 */
BK_API void bk_set_interrupt(bk_ctx ctx, bk_interrupt_fn cb, void *opaque);

/* ------------------------------------------------------------------- sugar */

/*
 * Convenience wrappers over the calls above. They are static inline, so they
 * add no symbol to the ABI and cannot drift from it; a binding for another
 * language ignores them and calls the real entry points.
 */

/* bk_eval on a NUL-terminated string. */
static inline bk_value bk_eval_str(bk_ctx ctx, const char *src) {
    return bk_eval(ctx, src, strlen(src));
}

/* Run for side effects only; non-zero if it failed. */
static inline int bk_exec(bk_ctx ctx, const char *src) {
    bk_value v = bk_eval(ctx, src, strlen(src));
    if (!v) return 1;
    bk_free(ctx, v);
    return 0;
}

/*
 * Install a single function, for hosts that do not have a table to hand.
 * Same contract as bk_register; `target` 0 means globalThis.
 */
static inline bk_status bk_register_fn(bk_ctx ctx, bk_value target, const char *name,
                                       bk_host_fn fn, int arity, unsigned int flags,
                                       void *udata) {
    bk_fn_def one[2];
    one[0].name = name; one[0].fn = fn; one[0].arity = arity;
    one[0].flags = flags; one[0].udata = udata;
    one[1].name = NULL; one[1].fn = NULL; one[1].arity = 0;
    one[1].flags = 0u; one[1].udata = NULL;
    return bk_register(ctx, target, one);
}

/* bk_string from a NUL-terminated string. */
static inline bk_value bk_str(bk_ctx ctx, const char *utf8) {
    return bk_string(ctx, utf8, strlen(utf8));
}

/* Property access with a NUL-terminated key. */
static inline bk_value bk_getp(bk_ctx ctx, bk_value obj, const char *key) {
    return bk_get(ctx, obj, key, strlen(key));
}
static inline bk_status bk_setp(bk_ctx ctx, bk_value obj, const char *key, bk_value val) {
    return bk_set(ctx, obj, key, strlen(key), val);
}
static inline bk_status bk_hasp(bk_ctx ctx, bk_value obj, const char *key, int *out) {
    return bk_has(ctx, obj, key, strlen(key), out);
}
static inline bk_status bk_delp(bk_ctx ctx, bk_value obj, const char *key, int *out) {
    return bk_delete(ctx, obj, key, strlen(key), out);
}
static inline bk_status bk_set_globalp(bk_ctx ctx, const char *name, bk_value v) {
    return bk_set_global(ctx, name, strlen(name), v);
}

/* Type predicates, for code that reads better than comparing bk_type_of. */
static inline int bk_is_undefined(bk_ctx c, bk_value v) { return bk_type_of(c, v) == BK_TYPE_UNDEFINED; }
static inline int bk_is_null(bk_ctx c, bk_value v)      { return bk_type_of(c, v) == BK_TYPE_NULL; }
static inline int bk_is_bool(bk_ctx c, bk_value v)      { return bk_type_of(c, v) == BK_TYPE_BOOLEAN; }
static inline int bk_is_number(bk_ctx c, bk_value v)    { return bk_type_of(c, v) == BK_TYPE_NUMBER; }
static inline int bk_is_string(bk_ctx c, bk_value v)    { return bk_type_of(c, v) == BK_TYPE_STRING; }
static inline int bk_is_object(bk_ctx c, bk_value v)    { return bk_type_of(c, v) == BK_TYPE_OBJECT; }
static inline int bk_is_function(bk_ctx c, bk_value v)  { return bk_type_of(c, v) == BK_TYPE_FUNCTION; }

/* Return helpers, so a callback body stays one line per case. */
static inline void bk_return_number(bk_ctx c, double d) { bk_return(c, bk_number(c, d)); }
static inline void bk_return_bool(bk_ctx c, int b)      { bk_return(c, bk_bool(c, b)); }
static inline void bk_return_null(bk_ctx c)             { bk_return(c, bk_null(c)); }
static inline void bk_return_string(bk_ctx c, const char *utf8, size_t len) {
    bk_return(c, bk_string(c, utf8, len));
}
static inline void bk_return_str(bk_ctx c, const char *utf8) {
    bk_return(c, bk_string(c, utf8, strlen(utf8)));
}

#ifdef __cplusplus
}
#endif

#endif /* BOOMKAT_H */
