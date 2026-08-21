//! Raw, unmodified FFI declarations for `include/boomkat.h`.
//!
//! This crate is a 1:1 transcription of the C header and adds no safety of its
//! own. Every function here is `unsafe`. For an idiomatic API use the `boomkat`
//! crate, which wraps these.
//!
//! Contract highlights carried over from the header:
//!
//! - `bk_ctx` is both the runtime and, inside a host callback, the call in
//!   progress. One context type serves every reader, constructor and property
//!   operation; a callback's context is valid only for that call.
//! - `bk_value` is an integer handle into a GC-rooted registry, **not** a
//!   pointer. Never dereference it. `0` (`BK_INVALID_VALUE`) means failure on
//!   every value-producing call.
//! - Handles carry the id of the runtime that issued them: resolving one
//!   against a different runtime is [`BK_ERR_INVALID`], not a resolution
//!   against whatever occupies that slot there.
//! - The ABI is not thread-safe and does not enforce that with a lock. One
//!   runtime must be driven from one thread at a time; two runtimes driven from
//!   two threads share nothing and do not interact.
//! - Nothing here aborts, panics, or unwinds across the boundary. That runs the
//!   other way too: a [`bk_host_fn`] the engine calls back into must not
//!   unwind, so any Rust panic inside one has to be caught before it returns.

#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_double, c_int, c_uint, c_ulonglong, c_void};

/// Opaque context: the runtime, or the live call inside a host function.
pub type bk_ctx = *mut c_void;

/// Opaque value handle (64 bits). Not a pointer; 0 means failure.
pub type bk_value = c_ulonglong;

/// A host callback JS can invoke by name.
///
/// It must return normally in every case: `bk_throw_error` and `bk_throw`
/// record a throw rather than unwinding, and nothing may unwind across this
/// boundary.
pub type bk_host_fn = unsafe extern "C" fn(ctx: bk_ctx, udata: *mut c_void);

/// One entry of a `bk_register` table. Mirrors `bk_fn_def` in the header;
/// field order and layout must match exactly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_fn_def {
    pub name: *const c_char,
    pub cfn: Option<bk_host_fn>,
    pub arity: c_int,
    pub flags: c_uint,
    pub udata: *mut c_void,
}

/// The all-zero entry that terminates a registration table.
pub const BK_FN_END: bk_fn_def = bk_fn_def {
    name: std::ptr::null(),
    cfn: None,
    arity: 0,
    flags: 0,
    udata: std::ptr::null_mut(),
};

/// Registration flag: `new fn()` is allowed; without it, it throws a TypeError.
pub const BK_CTOR: c_uint = 1;

/// The handle value that is never valid.
pub const BK_INVALID_VALUE: bk_value = 0;

// Status codes. 0 is success; all errors are negative.
pub const BK_OK: c_int = 0;
/// Allocation failed.
pub const BK_ERR_NOMEM: c_int = -1;
/// Compile failed; see `bk_error`.
pub const BK_ERR_SYNTAX: c_int = -2;
/// Uncaught JS exception; see `bk_error`.
pub const BK_ERR_THROW: c_int = -3;
/// Engine fault with no JS error attached.
pub const BK_ERR_INTERNAL: c_int = -4;
/// Null/bad argument, or bad handle.
pub const BK_ERR_INVALID: c_int = -5;
/// Value is not of the requested type.
pub const BK_ERR_TYPE: c_int = -6;
/// Buffer too small.
pub const BK_ERR_FULL: c_int = -7;
/// Aborted by the interrupt handler.
pub const BK_ERR_INTERRUPT: c_int = -8;

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
    /// Open a runtime. Returns null if it could not be created. Any number may
    /// be open at once; each owns its own heap, globals, shapes and interned
    /// strings, and they share nothing.
    pub fn bk_open() -> bk_ctx;

    /// Destroy the runtime and everything it owns, invalidating all handles.
    /// Safe with a null context.
    pub fn bk_close(ctx: bk_ctx);

    /// Static `"MAJOR.MINOR.PATCH"` string. Never null.
    pub fn bk_version() -> *const c_char;

    /// Compile and run `len` bytes of UTF-8 source for its completion value.
    /// Returns an owned handle, or 0 on failure with the detail in
    /// `bk_error` / `bk_error_code`. Microtasks are drained before returning.
    pub fn bk_eval(ctx: bk_ctx, src: *const c_char, len: usize) -> bk_value;

    /// As `bk_eval`, with `name` recorded as the script name for error
    /// reporting. Either name may be null.
    pub fn bk_eval_named(
        ctx: bk_ctx,
        src: *const c_char,
        len: usize,
        name: *const c_char,
        name_len: usize,
    ) -> bk_value;

    /// Run pending promise jobs. `bk_eval` already drains before returning.
    /// Re-entrancy-guarded. Returns `BK_OK`, or `BK_ERR_INTERRUPT` when an
    /// interrupt fired inside a job.
    pub fn bk_drain(ctx: bk_ctx) -> c_int;

    /// Release an owned handle. Safe with `0`, a scope handle, or an
    /// already-freed handle.
    pub fn bk_free(ctx: bk_ctx, v: bk_value);

    /// Copy a scope value into the registry, yielding an owned handle that
    /// outlives the current callback. 0 on failure.
    pub fn bk_persist(ctx: bk_ctx, v: bk_value) -> bk_value;

    // ------------------------------------------------------------- errors

    /// Message for the most recent failure. Never null; empty when no error.
    /// Owned by the context and valid only until the next `bk_*` call.
    pub fn bk_error(ctx: bk_ctx) -> *const c_char;

    /// Status code matching [`bk_error`], or [`BK_OK`] if none.
    pub fn bk_error_code(ctx: bk_ctx) -> c_int;

    /// Names for logging. Never null, even for an unknown code.
    pub fn bk_status_str(status: c_int) -> *const c_char;
    pub fn bk_type_str(ty: c_int) -> *const c_char;

    // ------------------------------------------------------ reading values

    /// Type of a value. An invalid handle reports [`BK_TYPE_UNDEFINED`], so
    /// this cannot fail.
    pub fn bk_type_of(ctx: bk_ctx, v: bk_value) -> c_int;

    /// Read a number. Does not coerce.
    pub fn bk_read_number(ctx: bk_ctx, v: bk_value, out: *mut c_double) -> c_int;

    /// Read a boolean as 0 or 1. Does not coerce.
    pub fn bk_read_bool(ctx: bk_ctx, v: bk_value, out: *mut c_int) -> c_int;

    /// Copy a string value out as NUL-terminated UTF-8 without allocating.
    /// Two-call protocol: pass `buf` null to measure into `out_len`, then pass
    /// a buffer of at least `*out_len + 1`.
    pub fn bk_read_string(
        ctx: bk_ctx,
        v: bk_value,
        buf: *mut c_char,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;

    // ------------------------------------------------------ coercion tier

    /// ES abstract operations. Each may run user code and therefore throw;
    /// on a throw they report through `bk_error_code` and return the zero
    /// value shown in the header.
    pub fn bk_to_number(ctx: bk_ctx, v: bk_value) -> c_double;
    pub fn bk_to_bool(ctx: bk_ctx, v: bk_value) -> c_int;
    pub fn bk_to_string(ctx: bk_ctx, v: bk_value) -> bk_value;

    /// Any value as text, the way String(v) would render it. Context-owned,
    /// valid until the fourth following `bk_cstr` call on the context. Null
    /// only if the conversion threw.
    pub fn bk_cstr(ctx: bk_ctx, v: bk_value, out_len: *mut usize) -> *const c_char;

    /// As `bk_cstr`, but the caller owns the result and frees it with free().
    /// Null if the conversion threw or allocation failed.
    pub fn bk_strdup(ctx: bk_ctx, v: bk_value, out_len: *mut usize) -> *mut c_char;

    // ----------------------------------------------------- building values

    /// Constructors. Each returns an owned handle, or 0 on failure.
    pub fn bk_number(ctx: bk_ctx, d: c_double) -> bk_value;
    pub fn bk_bool(ctx: bk_ctx, b: c_int) -> bk_value;
    pub fn bk_null(ctx: bk_ctx) -> bk_value;
    pub fn bk_undefined(ctx: bk_ctx) -> bk_value;
    pub fn bk_string(ctx: bk_ctx, utf8: *const c_char, len: usize) -> bk_value;
    pub fn bk_object(ctx: bk_ctx) -> bk_value;
    pub fn bk_array(ctx: bk_ctx) -> bk_value;
    pub fn bk_array_of(ctx: bk_ctx, elems: *const bk_value, n: c_uint) -> bk_value;
    pub fn bk_global(ctx: bk_ctx) -> bk_value;

    // ---------------------------------------------------------- properties

    pub fn bk_get(ctx: bk_ctx, obj: bk_value, key: *const c_char, key_len: usize) -> bk_value;
    pub fn bk_get_index(ctx: bk_ctx, obj: bk_value, idx: c_uint) -> bk_value;
    pub fn bk_set(
        ctx: bk_ctx,
        obj: bk_value,
        key: *const c_char,
        key_len: usize,
        val: bk_value,
    ) -> c_int;
    pub fn bk_set_index(ctx: bk_ctx, obj: bk_value, idx: c_uint, val: bk_value) -> c_int;
    pub fn bk_has(
        ctx: bk_ctx,
        obj: bk_value,
        key: *const c_char,
        key_len: usize,
        out: *mut c_int,
    ) -> c_int;
    pub fn bk_delete(
        ctx: bk_ctx,
        obj: bk_value,
        key: *const c_char,
        key_len: usize,
        out: *mut c_int,
    ) -> c_int;
    pub fn bk_keys(ctx: bk_ctx, obj: bk_value) -> bk_value;

    // --------------------------------------------------------------- calls

    /// Call a JS function. Pass 0 for `this_val` to call with undefined, and
    /// null/0 for no arguments. Returns an owned handle, or 0 on failure.
    pub fn bk_call(
        ctx: bk_ctx,
        func: bk_value,
        this_val: bk_value,
        argv: *const bk_value,
        argc: c_uint,
    ) -> bk_value;

    // ------------------------------------------------------- host functions

    /// Install a whole table of functions in one call. `target` 0 means
    /// globalThis. The table ends at the first entry with a null name.
    /// Returns the failure of the first entry that could not be installed.
    pub fn bk_register(ctx: bk_ctx, target: bk_value, defs: *const bk_fn_def) -> c_int;

    /// Bind `name` to `v` as a global. The value is copied in.
    pub fn bk_set_global(ctx: bk_ctx, name: *const c_char, name_len: usize, v: bk_value)
        -> c_int;

    /// Number of arguments this call was made with.
    pub fn bk_argc(ctx: bk_ctx) -> c_uint;

    /// Handle to argument `i`; at or past `bk_argc` this is undefined, not an
    /// invalid handle.
    pub fn bk_arg(ctx: bk_ctx, i: c_uint) -> bk_value;

    /// The `this` receiver. Strict semantics: undefined stays undefined.
    pub fn bk_this(ctx: bk_ctx) -> bk_value;

    /// `new.target`, or undefined on a plain call.
    pub fn bk_new_target(ctx: bk_ctx) -> bk_value;

    /// Non-zero when invoked through `new` or `super()`.
    pub fn bk_is_construct(ctx: bk_ctx) -> c_int;

    /// Set the return value. A callback that sets none yields undefined.
    pub fn bk_return(ctx: bk_ctx, v: bk_value);

    /// Record a throw of a fresh Error of `kind` carrying NUL-terminated
    /// `msg`. Does not unwind; the callback must still return.
    pub fn bk_throw_error(ctx: bk_ctx, kind: c_int, msg: *const c_char);

    /// Record a throw of an arbitrary value. Does not unwind.
    pub fn bk_throw(ctx: bk_ctx, v: bk_value);

    // ----------------------------------------------------------- interrupt

    /// Install, replace (or with null, clear) the interrupt handler.
    pub fn bk_set_interrupt(ctx: bk_ctx, cb: Option<bk_interrupt_fn>, opaque: *mut c_void);
}

/// Poll handler run at VM safepoints. Return non-zero to abort the running
/// script as BK_ERR_INTERRUPT. Must not call any bk_* function.
pub type bk_interrupt_fn = unsafe extern "C" fn(ctx: bk_ctx, opaque: *mut c_void) -> c_int;
