//! Raw, unmodified FFI declarations for `include/boomkat.h`.
//!
//! This crate is a 1:1 transcription of the C header and adds no safety of its
//! own. Every function here is `unsafe`. For an idiomatic API use the `boomkat`
//! crate, which wraps these.
//!
//! Contract highlights carried over from the header:
//!
//! - `bk_value` is an integer handle into a GC-rooted slot registry, **not** a
//!   pointer. Never dereference it. `0` is never valid.
//! - Several runtimes may be open at once. They share nothing, and a handle
//!   names a slot in exactly one of them: passing it to another runtime's
//!   reader is [`BK_ERR_INVALID`], not a resolution against that runtime.
//! - Readers come in two tiers. [`bk_get_number`] and friends take a
//!   `bk_runtime`; [`bk_ctx_get_number`] and friends take a `bk_call_ctx`.
//!   Neither accepts NULL, and only the context tier resolves the scope handles
//!   [`bk_arg`], [`bk_this`] and [`bk_new_target`] return.
//! - The ABI is not thread-safe and does not enforce that with a lock. One
//!   runtime must be driven from one thread at a time; two runtimes driven from
//!   two threads share nothing and do not interact.
//! - Nothing here aborts, panics, or unwinds across the boundary. That runs the
//!   other way too: a [`bk_host_fn`] the engine calls back into must not
//!   unwind, so any Rust panic inside one has to be caught before it returns.

#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_double, c_int, c_uint, c_void};

/// Opaque runtime pointer.
pub type bk_runtime = *mut c_void;

/// Opaque value handle. Not a pointer.
pub type bk_value = c_uint;

/// Opaque per-call context handed to a host function. Valid only for the
/// duration of that call; never store one.
pub type bk_call_ctx = *mut c_void;

/// A host callback JS can invoke by name.
///
/// It must return normally in every case: `bk_throw_error` and `bk_throw`
/// record a throw rather than unwinding, and nothing may unwind across this
/// boundary.
pub type bk_host_fn = unsafe extern "C" fn(ctx: bk_call_ctx, udata: *mut c_void);

/// The handle value that is never valid.
pub const BK_INVALID_VALUE: bk_value = 0;

// Status codes. 0 is success; all errors are negative.
pub const BK_OK: c_int = 0;
/// Allocation failed.
pub const BK_ERR_NOMEM: c_int = -1;
/// Compile failed; see `bk_last_error`.
pub const BK_ERR_SYNTAX: c_int = -2;
/// Uncaught JS exception; see `bk_last_error`.
pub const BK_ERR_THROW: c_int = -3;
/// Engine fault with no JS error attached.
pub const BK_ERR_INTERNAL: c_int = -4;
/// Null/bad argument, or bad handle.
pub const BK_ERR_INVALID: c_int = -5;
/// Value is not of the requested type.
pub const BK_ERR_TYPE: c_int = -6;
/// Buffer too small, or the slot table is exhausted.
pub const BK_ERR_FULL: c_int = -7;

// Value types as reported by `bk_type_of`.
pub const BK_TYPE_UNDEFINED: c_int = 0;
pub const BK_TYPE_NULL: c_int = 1;
pub const BK_TYPE_BOOLEAN: c_int = 2;
pub const BK_TYPE_NUMBER: c_int = 3;
pub const BK_TYPE_STRING: c_int = 4;
pub const BK_TYPE_OBJECT: c_int = 5;
pub const BK_TYPE_FUNCTION: c_int = 6;
/// Symbol, bigint, etc.
pub const BK_TYPE_OTHER: c_int = 7;

// Error kinds for `bk_throw_error`.
pub const BK_ERROR: c_int = 0;
pub const BK_ERROR_TYPE: c_int = 1;
pub const BK_ERROR_RANGE: c_int = 2;
pub const BK_ERROR_REFERENCE: c_int = 3;
pub const BK_ERROR_SYNTAX: c_int = 4;

extern "C" {
    /// Create a runtime. Any number may be open at once; each owns its own
    /// heap, globals, shapes and interned strings, and they share nothing.
    pub fn bk_open(out_rt: *mut bk_runtime) -> c_int;

    /// Destroy the runtime and everything it owns, invalidating all handles.
    /// Safe with a null runtime.
    pub fn bk_close(rt: bk_runtime);

    /// Static `"MAJOR.MINOR.PATCH"` string. Never null.
    pub fn bk_version() -> *const c_char;

    /// Compile and run `len` bytes of UTF-8 source for its completion value.
    /// `out_val` may be null to run purely for side effects.
    pub fn bk_eval(
        rt: bk_runtime,
        src: *const c_char,
        len: usize,
        out_val: *mut bk_value,
    ) -> c_int;

    /// Release a handle. Safe with `0` or an already-freed handle.
    pub fn bk_value_free(rt: bk_runtime, v: bk_value);

    /// Type of a value. An invalid handle reports [`BK_TYPE_UNDEFINED`], so
    /// this cannot fail.
    pub fn bk_type_of(rt: bk_runtime, v: bk_value) -> c_int;

    /// Read a number. Does not coerce.
    pub fn bk_get_number(rt: bk_runtime, v: bk_value, out: *mut c_double) -> c_int;

    /// Read a boolean as 0 or 1. Does not coerce.
    pub fn bk_get_bool(rt: bk_runtime, v: bk_value, out: *mut c_int) -> c_int;

    /// Copy a string out as NUL-terminated UTF-8, converting the engine's
    /// internal CESU-8. Two-call protocol: pass `buf` null to measure into
    /// `out_len`, then pass a buffer of at least `*out_len + 1`.
    pub fn bk_get_string(
        rt: bk_runtime,
        v: bk_value,
        buf: *mut c_char,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;

    // The context tier of the readers, for use inside a host callback. Same
    // semantics as the runtime tier above, addressing the runtime the call
    // belongs to; these are the only forms that resolve the scope handles
    // [`bk_arg`], [`bk_this`] and [`bk_new_target`] return.
    pub fn bk_ctx_type_of(ctx: bk_call_ctx, v: bk_value) -> c_int;
    pub fn bk_ctx_get_number(ctx: bk_call_ctx, v: bk_value, out: *mut c_double) -> c_int;
    pub fn bk_ctx_get_bool(ctx: bk_call_ctx, v: bk_value, out: *mut c_int) -> c_int;
    pub fn bk_ctx_get_string(
        ctx: bk_call_ctx,
        v: bk_value,
        buf: *mut c_char,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;

    /// The runtime owning a callback's context, for a host that needs to
    /// persist a value or evaluate from inside a call.
    pub fn bk_ctx_runtime(ctx: bk_call_ctx) -> bk_runtime;

    /// Message for the most recent failure. Never null; empty when no error.
    /// Owned by the runtime and valid only until the next `bk_*` call.
    pub fn bk_last_error(rt: bk_runtime) -> *const c_char;

    /// Status code matching [`bk_last_error`], or [`BK_OK`] if none.
    pub fn bk_last_error_code(rt: bk_runtime) -> c_int;

    /// Run pending promise jobs. `bk_eval` already drains before returning.
    pub fn bk_drain_microtasks(rt: bk_runtime);

    // ------------------------------------------------------- host functions

    /// Bind `cfn` as a global function named `name` (`name_len` bytes of
    /// UTF-8). `udata` is passed back to every invocation untouched and is
    /// never dereferenced by the engine. `arity` becomes `.length`; a zero
    /// `constructable` makes `new fn()` throw a TypeError. Registration is
    /// permanent for the runtime's lifetime.
    pub fn bk_register_fn(
        rt: bk_runtime,
        name: *const c_char,
        name_len: usize,
        cfn: bk_host_fn,
        udata: *mut c_void,
        arity: c_int,
        constructable: c_int,
    ) -> c_int;

    /// Number of arguments this call was made with.
    pub fn bk_argc(ctx: bk_call_ctx) -> c_uint;

    /// Handle to argument `i`; at or past `bk_argc` this is undefined, not an
    /// invalid handle.
    pub fn bk_arg(ctx: bk_call_ctx, i: c_uint) -> bk_value;

    /// The `this` receiver. Strict semantics: undefined stays undefined.
    pub fn bk_this(ctx: bk_call_ctx) -> bk_value;

    /// `new.target`, or undefined on a plain call.
    pub fn bk_new_target(ctx: bk_call_ctx) -> bk_value;

    /// Non-zero when invoked through `new` or `super()`.
    pub fn bk_is_construct(ctx: bk_call_ctx) -> c_int;

    /// Set the return value. A callback that sets none yields undefined.
    pub fn bk_return(ctx: bk_call_ctx, v: bk_value);
    pub fn bk_return_number(ctx: bk_call_ctx, d: c_double);
    pub fn bk_return_bool(ctx: bk_call_ctx, b: c_int);
    pub fn bk_return_null(ctx: bk_call_ctx);

    /// Return a fresh JS string built from `len` bytes of UTF-8.
    pub fn bk_return_string(ctx: bk_call_ctx, utf8: *const c_char, len: usize);

    /// Record a throw of a fresh Error of `kind` carrying NUL-terminated
    /// `msg`. Does not unwind; the callback must still return.
    pub fn bk_throw_error(ctx: bk_call_ctx, kind: c_int, msg: *const c_char);

    /// Record a throw of an arbitrary value. Does not unwind.
    pub fn bk_throw(ctx: bk_call_ctx, v: bk_value);

    /// Copy a scope value into the runtime's global registry, yielding a handle
    /// that outlives the callback and must be freed with `bk_value_free`.
    pub fn bk_value_persist(ctx: bk_call_ctx, v: bk_value) -> bk_value;

    /// Call a JS function from inside a host callback. On [`BK_OK`],
    /// `*out_val` (when non-null) receives a runtime-owned handle the caller
    /// must free. A callee throw is recorded on `ctx` and reported as
    /// [`BK_ERR_THROW`]; host recursion is bounded by a RangeError.
    pub fn bk_call(
        ctx: bk_call_ctx,
        func: bk_value,
        argv: *const bk_value,
        argc: c_uint,
        this_val: bk_value,
        out_val: *mut bk_value,
    ) -> c_int;
}
