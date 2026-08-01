/*
 * jse.h — C99 embedding ABI for the duktape-c3 JavaScript engine.
 *
 * Prefix rationale: "jse_" = JS Engine. The project forbids duk_/DUK_ in new
 * code (the library may be renamed), and js_/JS_ collides with QuickJS, whose
 * sources are already vendored in this build. jse_ is short, neutral, and
 * collision-free against every vendored C symbol.
 *
 * DESIGN CONTRACT
 *   - Fully opaque. No engine struct is visible here. TVal is never exposed:
 *     it is 8 or 16 bytes depending on a compile-time feature, and all of its
 *     accessors are C3 macros with no linkable symbol.
 *   - Values are referenced by jse_value, an integer handle into a GC-rooted
 *     slot registry. A handle is NOT a pointer and must never be dereferenced.
 *   - Every call returns a status code or a nullable handle. Nothing aborts,
 *     panics, or longjmps across this boundary.
 *   - NOT thread-safe, and single-runtime per process (see jse_open).
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
 *   - Handles from jse_eval stay valid until jse_value_free or jse_close.
 *     They survive garbage collection: the registry is a GC root.
 *   - Handles leak if never freed. The registry holds 1024 live handles;
 *     exceeding that returns JSE_ERR_FULL.
 *   - Strings are copied into caller-owned buffers. The ABI never hands out a
 *     pointer the caller must free, so there is no jse_free_string.
 *   - const char* from jse_last_error / jse_version point to storage owned by
 *     the runtime. Copy before the next call; do not free.
 */

#ifndef JSE_H
#define JSE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(JSE_DLL)
#  define JSE_API __declspec(dllimport)
#else
#  define JSE_API
#endif

/* Opaque runtime handle. */
typedef void *jse_runtime;

/* Opaque value handle. 0 is never a valid handle. */
typedef unsigned int jse_value;
#define JSE_INVALID_VALUE ((jse_value)0)

/* Status codes. 0 is success; all errors are negative. */
typedef enum {
    JSE_OK           =  0,
    JSE_ERR_NOMEM    = -1,  /* allocation failed */
    JSE_ERR_SYNTAX   = -2,  /* compile failed; see jse_last_error */
    JSE_ERR_THROW    = -3,  /* uncaught JS exception; see jse_last_error */
    JSE_ERR_INTERNAL = -4,  /* engine fault with no JS error attached */
    JSE_ERR_INVALID  = -5,  /* null/bad argument, or bad handle */
    JSE_ERR_TYPE     = -6,  /* value is not of the requested type */
    JSE_ERR_FULL     = -7   /* buffer too small, or slot table exhausted */
} jse_status;

/* Value types as reported by jse_type_of. */
typedef enum {
    JSE_TYPE_UNDEFINED = 0,
    JSE_TYPE_NULL      = 1,
    JSE_TYPE_BOOLEAN   = 2,
    JSE_TYPE_NUMBER    = 3,
    JSE_TYPE_STRING    = 4,
    JSE_TYPE_OBJECT    = 5,
    JSE_TYPE_FUNCTION  = 6,
    JSE_TYPE_OTHER     = 7   /* symbol, bigint, etc. */
} jse_type;

/* ---------------------------------------------------------------- lifecycle */

/*
 * Create the runtime and store it in *out_rt.
 *
 * Only ONE runtime may exist per process: the engine keeps process-global
 * state (the compiler's error buffer and the hobject active-heap pointer).
 * A second call while one is open returns JSE_ERR_INVALID rather than
 * corrupting the first. Returns JSE_OK, JSE_ERR_NOMEM, or JSE_ERR_INVALID.
 */
JSE_API int jse_open(jse_runtime *out_rt);

/*
 * Destroy the runtime and everything it owns. All outstanding handles become
 * invalid. Safe to call with NULL. Teardown order is handled internally.
 */
JSE_API void jse_close(jse_runtime rt);

/* Static version string, "MAJOR.MINOR.PATCH". Never NULL. */
JSE_API const char *jse_version(void);

/* --------------------------------------------------------------------- eval */

/*
 * Compile and run `len` bytes of UTF-8 source, evaluated for its completion
 * value (so "40 + 2" yields 42, matching eval() semantics).
 *
 * On JSE_OK, if out_val is non-NULL it receives a handle to the result, which
 * the caller owns and must release with jse_value_free. Pass NULL for out_val
 * to run purely for side effects.
 *
 * On failure *out_val is set to JSE_INVALID_VALUE and jse_last_error carries
 * the detail. Microtasks are drained automatically before returning.
 *
 * Returns JSE_OK, JSE_ERR_SYNTAX, JSE_ERR_THROW, JSE_ERR_INTERNAL,
 * JSE_ERR_INVALID, or JSE_ERR_FULL.
 */
JSE_API int jse_eval(jse_runtime rt, const char *src, size_t len,
                     jse_value *out_val);

/* Release a handle. Safe with 0 or an already-freed handle. */
JSE_API void jse_value_free(jse_runtime rt, jse_value v);

/* ------------------------------------------------------------------ readers */

/*
 * Type of a value. An invalid or freed handle reports JSE_TYPE_UNDEFINED, so
 * this never fails and needs no status code.
 */
JSE_API int jse_type_of(jse_runtime rt, jse_value v);

/*
 * Read a number. Accepts both internal numeric representations (double and
 * the 47-bit fast integer), so any JS number succeeds.
 * Returns JSE_OK, JSE_ERR_TYPE, or JSE_ERR_INVALID.
 */
JSE_API int jse_get_number(jse_runtime rt, jse_value v, double *out);

/*
 * Read a boolean into *out as 0 or 1. Strict: does not coerce.
 * Returns JSE_OK, JSE_ERR_TYPE, or JSE_ERR_INVALID.
 */
JSE_API int jse_get_bool(jse_runtime rt, jse_value v, int *out);

/*
 * Copy a string out as NUL-terminated UTF-8. Strict: does not coerce, so call
 * String(x) in JS first if you want stringification.
 *
 * Two-call protocol. Pass buf == NULL to measure: *out_len receives the byte
 * length excluding the NUL, and the call returns JSE_OK. Then pass a buffer of
 * at least *out_len + 1.
 *
 * The engine stores text as CESU-8; this converts to standard UTF-8, so astral
 * characters emerge as proper 4-byte sequences rather than surrogate halves.
 *
 * Returns JSE_OK, JSE_ERR_FULL (cap too small), JSE_ERR_TYPE, or
 * JSE_ERR_INVALID.
 */
JSE_API int jse_get_string(jse_runtime rt, jse_value v, char *buf, size_t cap,
                           size_t *out_len);

/* ------------------------------------------------------- errors / microtasks */

/*
 * Message for the most recent failure on this runtime, as a NUL-terminated
 * UTF-8 string owned by the runtime. Never NULL; empty when no error. Valid
 * until the next jse_* call. Formatted without re-entering the VM, so a
 * throwing user toString cannot recurse here.
 *
 * Every jse_ call that can fail sets this before returning a non-zero status,
 * including the readers (jse_get_number / jse_get_bool / jse_get_string), so a
 * host may log it unconditionally on failure. Those readers also clear it on
 * entry, so a message never survives from an unrelated earlier call.
 *
 * The one exception is a NULL rt or NULL out-parameter: that returns
 * JSE_ERR_INVALID with no runtime to record the message in.
 *
 * For a thrown Error the text is "Name: message" ("TypeError: x is not a
 * function"), which lets a host map it onto its own exception classes; `name`
 * is read off the prototype chain. A thrown primitive formats as its value, so
 * `throw 42` reports "42" and `throw null` reports "null". A thrown object with
 * neither `name` nor `message` reports "uncaught exception (object)". The
 * prototype walk stops at a Proxy and ignores accessors rather than invoking a
 * trap or getter, since this runs on the unwind path.
 */
JSE_API const char *jse_last_error(jse_runtime rt);

/* Status code matching jse_last_error, or JSE_OK if none. */
JSE_API int jse_last_error_code(jse_runtime rt);

/*
 * Run pending promise jobs. jse_eval already drains before returning; call
 * this after resolving promises from host code. Re-entrancy-guarded.
 */
JSE_API void jse_drain_microtasks(jse_runtime rt);

/*
 * NOT IN v1 — host native function registration, and calling a JS function
 * from C.
 *
 * Native registration is impossible without engine changes. Built-ins live in
 * a compile-time C3 enum (~800 members); both the metadata table and
 * builtin_dispatch_table are generated from it at compile time, and the array
 * is sized [Builtin.LAST.ordinal] and filled at @init. A JS function value
 * stores an ordinal (builtin_fn_index), and dispatch is always
 * builtin_dispatch_table[ordinal] -- an index, never a host pointer. Even the
 * "lightfunc" value tag holds an ordinal cast to a pointer, not a code
 * address. There is no runtime table to append to, so no amount of shim code
 * can register a C callback.
 *
 * Calling a JS function (jse_call) was omitted deliberately, not for lack of a
 * mechanism: vm_call_fn_impl works and was verified. It returns a bare value
 * and signals failure through a heap flag rather than a status, and argument
 * arrays must be GC-visible, so a safe wrapper needs argument marshalling and
 * error-state plumbing beyond a minimal v1. Until then, wrap the call in JS
 * source and use jse_eval.
 */

#ifdef __cplusplus
}
#endif

#endif /* JSE_H */
