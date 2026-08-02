//! Raw, unmodified FFI declarations for `include/jse.h`.
//!
//! This crate is a 1:1 transcription of the C header and adds no safety of its
//! own. Every function here is `unsafe`. For an idiomatic API use the `jse`
//! crate, which wraps these.
//!
//! Contract highlights carried over from the header:
//!
//! - `jse_value` is an integer handle into a GC-rooted slot registry, **not** a
//!   pointer. Never dereference it. `0` is never valid.
//! - Several runtimes may be open at once. They share nothing, and a handle
//!   names a slot in exactly one of them: passing it to another runtime's
//!   reader is [`JSE_ERR_INVALID`], not a resolution against that runtime.
//! - Readers come in two tiers. [`jse_get_number`] and friends take a
//!   `jse_runtime`; [`jse_ctx_get_number`] and friends take a `jse_call_ctx`.
//!   Neither accepts NULL, and only the context tier resolves the scope handles
//!   [`jse_arg`], [`jse_this`] and [`jse_new_target`] return.
//! - The ABI is not thread-safe and does not enforce that with a lock. One
//!   runtime must be driven from one thread at a time; two runtimes driven from
//!   two threads share nothing and do not interact.
//! - Nothing here aborts, panics, or unwinds across the boundary. That runs the
//!   other way too: a [`jse_host_fn`] the engine calls back into must not
//!   unwind, so any Rust panic inside one has to be caught before it returns.

#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_double, c_int, c_uint, c_void};

/// Opaque runtime pointer.
pub type jse_runtime = *mut c_void;

/// Opaque value handle. Not a pointer.
pub type jse_value = c_uint;

/// Opaque per-call context handed to a host function. Valid only for the
/// duration of that call; never store one.
pub type jse_call_ctx = *mut c_void;

/// A host callback JS can invoke by name.
///
/// It must return normally in every case: `jse_throw_error` and `jse_throw`
/// record a throw rather than unwinding, and nothing may unwind across this
/// boundary.
pub type jse_host_fn = unsafe extern "C" fn(ctx: jse_call_ctx, udata: *mut c_void);

/// The handle value that is never valid.
pub const JSE_INVALID_VALUE: jse_value = 0;

// Status codes. 0 is success; all errors are negative.
pub const JSE_OK: c_int = 0;
/// Allocation failed.
pub const JSE_ERR_NOMEM: c_int = -1;
/// Compile failed; see `jse_last_error`.
pub const JSE_ERR_SYNTAX: c_int = -2;
/// Uncaught JS exception; see `jse_last_error`.
pub const JSE_ERR_THROW: c_int = -3;
/// Engine fault with no JS error attached.
pub const JSE_ERR_INTERNAL: c_int = -4;
/// Null/bad argument, or bad handle.
pub const JSE_ERR_INVALID: c_int = -5;
/// Value is not of the requested type.
pub const JSE_ERR_TYPE: c_int = -6;
/// Buffer too small, or the slot table is exhausted.
pub const JSE_ERR_FULL: c_int = -7;

// Value types as reported by `jse_type_of`.
pub const JSE_TYPE_UNDEFINED: c_int = 0;
pub const JSE_TYPE_NULL: c_int = 1;
pub const JSE_TYPE_BOOLEAN: c_int = 2;
pub const JSE_TYPE_NUMBER: c_int = 3;
pub const JSE_TYPE_STRING: c_int = 4;
pub const JSE_TYPE_OBJECT: c_int = 5;
pub const JSE_TYPE_FUNCTION: c_int = 6;
/// Symbol, bigint, etc.
pub const JSE_TYPE_OTHER: c_int = 7;

// Error kinds for `jse_throw_error`.
pub const JSE_ERROR: c_int = 0;
pub const JSE_ERROR_TYPE: c_int = 1;
pub const JSE_ERROR_RANGE: c_int = 2;
pub const JSE_ERROR_REFERENCE: c_int = 3;
pub const JSE_ERROR_SYNTAX: c_int = 4;

extern "C" {
    /// Create a runtime. Any number may be open at once; each owns its own
    /// heap, globals, shapes and interned strings, and they share nothing.
    pub fn jse_open(out_rt: *mut jse_runtime) -> c_int;

    /// Destroy the runtime and everything it owns, invalidating all handles.
    /// Safe with a null runtime.
    pub fn jse_close(rt: jse_runtime);

    /// Static `"MAJOR.MINOR.PATCH"` string. Never null.
    pub fn jse_version() -> *const c_char;

    /// Compile and run `len` bytes of UTF-8 source for its completion value.
    /// `out_val` may be null to run purely for side effects.
    pub fn jse_eval(
        rt: jse_runtime,
        src: *const c_char,
        len: usize,
        out_val: *mut jse_value,
    ) -> c_int;

    /// Release a handle. Safe with `0` or an already-freed handle.
    pub fn jse_value_free(rt: jse_runtime, v: jse_value);

    /// Type of a value. An invalid handle reports [`JSE_TYPE_UNDEFINED`], so
    /// this cannot fail.
    pub fn jse_type_of(rt: jse_runtime, v: jse_value) -> c_int;

    /// Read a number. Does not coerce.
    pub fn jse_get_number(rt: jse_runtime, v: jse_value, out: *mut c_double) -> c_int;

    /// Read a boolean as 0 or 1. Does not coerce.
    pub fn jse_get_bool(rt: jse_runtime, v: jse_value, out: *mut c_int) -> c_int;

    /// Copy a string out as NUL-terminated UTF-8, converting the engine's
    /// internal CESU-8. Two-call protocol: pass `buf` null to measure into
    /// `out_len`, then pass a buffer of at least `*out_len + 1`.
    pub fn jse_get_string(
        rt: jse_runtime,
        v: jse_value,
        buf: *mut c_char,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;

    // The context tier of the readers, for use inside a host callback. Same
    // semantics as the runtime tier above, addressing the runtime the call
    // belongs to; these are the only forms that resolve the scope handles
    // [`jse_arg`], [`jse_this`] and [`jse_new_target`] return.
    pub fn jse_ctx_type_of(ctx: jse_call_ctx, v: jse_value) -> c_int;
    pub fn jse_ctx_get_number(ctx: jse_call_ctx, v: jse_value, out: *mut c_double) -> c_int;
    pub fn jse_ctx_get_bool(ctx: jse_call_ctx, v: jse_value, out: *mut c_int) -> c_int;
    pub fn jse_ctx_get_string(
        ctx: jse_call_ctx,
        v: jse_value,
        buf: *mut c_char,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;

    /// The runtime owning a callback's context, for a host that needs to
    /// persist a value or evaluate from inside a call.
    pub fn jse_ctx_runtime(ctx: jse_call_ctx) -> jse_runtime;

    /// Message for the most recent failure. Never null; empty when no error.
    /// Owned by the runtime and valid only until the next `jse_*` call.
    pub fn jse_last_error(rt: jse_runtime) -> *const c_char;

    /// Status code matching [`jse_last_error`], or [`JSE_OK`] if none.
    pub fn jse_last_error_code(rt: jse_runtime) -> c_int;

    /// Run pending promise jobs. `jse_eval` already drains before returning.
    pub fn jse_drain_microtasks(rt: jse_runtime);

    // ------------------------------------------------------- host functions

    /// Bind `cfn` as a global function named `name` (`name_len` bytes of
    /// UTF-8). `udata` is passed back to every invocation untouched and is
    /// never dereferenced by the engine. `arity` becomes `.length`; a zero
    /// `constructable` makes `new fn()` throw a TypeError. Registration is
    /// permanent for the runtime's lifetime.
    pub fn jse_register_fn(
        rt: jse_runtime,
        name: *const c_char,
        name_len: usize,
        cfn: jse_host_fn,
        udata: *mut c_void,
        arity: c_int,
        constructable: c_int,
    ) -> c_int;

    /// Number of arguments this call was made with.
    pub fn jse_argc(ctx: jse_call_ctx) -> c_uint;

    /// Handle to argument `i`; at or past `jse_argc` this is undefined, not an
    /// invalid handle.
    pub fn jse_arg(ctx: jse_call_ctx, i: c_uint) -> jse_value;

    /// The `this` receiver. Strict semantics: undefined stays undefined.
    pub fn jse_this(ctx: jse_call_ctx) -> jse_value;

    /// `new.target`, or undefined on a plain call.
    pub fn jse_new_target(ctx: jse_call_ctx) -> jse_value;

    /// Non-zero when invoked through `new` or `super()`.
    pub fn jse_is_construct(ctx: jse_call_ctx) -> c_int;

    /// Set the return value. A callback that sets none yields undefined.
    pub fn jse_return(ctx: jse_call_ctx, v: jse_value);
    pub fn jse_return_number(ctx: jse_call_ctx, d: c_double);
    pub fn jse_return_bool(ctx: jse_call_ctx, b: c_int);
    pub fn jse_return_null(ctx: jse_call_ctx);

    /// Return a fresh JS string built from `len` bytes of UTF-8.
    pub fn jse_return_string(ctx: jse_call_ctx, utf8: *const c_char, len: usize);

    /// Record a throw of a fresh Error of `kind` carrying NUL-terminated
    /// `msg`. Does not unwind; the callback must still return.
    pub fn jse_throw_error(ctx: jse_call_ctx, kind: c_int, msg: *const c_char);

    /// Record a throw of an arbitrary value. Does not unwind.
    pub fn jse_throw(ctx: jse_call_ctx, v: jse_value);

    /// Copy a scope value into the runtime's global registry, yielding a handle
    /// that outlives the callback and must be freed with `jse_value_free`.
    pub fn jse_value_persist(ctx: jse_call_ctx, v: jse_value) -> jse_value;

    /// Call a JS function from inside a host callback. On [`JSE_OK`],
    /// `*out_val` (when non-null) receives a runtime-owned handle the caller
    /// must free. A callee throw is recorded on `ctx` and reported as
    /// [`JSE_ERR_THROW`]; host recursion is bounded by a RangeError.
    pub fn jse_call(
        ctx: jse_call_ctx,
        func: jse_value,
        argv: *const jse_value,
        argc: c_uint,
        this_val: jse_value,
        out_val: *mut jse_value,
    ) -> c_int;
}
