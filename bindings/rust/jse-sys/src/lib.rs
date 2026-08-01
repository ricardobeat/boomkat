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
//! - Only one runtime may exist per process; a second [`jse_open`] returns
//!   [`JSE_ERR_INVALID`].
//! - The ABI is not thread-safe and does not enforce that with a lock.
//! - Nothing here aborts, panics, or unwinds across the boundary.

#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_double, c_int, c_uint, c_void};

/// Opaque runtime pointer.
pub type jse_runtime = *mut c_void;

/// Opaque value handle. Not a pointer.
pub type jse_value = c_uint;

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

extern "C" {
    /// Create the runtime. One per process; a second call returns
    /// [`JSE_ERR_INVALID`].
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

    /// Message for the most recent failure. Never null; empty when no error.
    /// Owned by the runtime and valid only until the next `jse_*` call.
    pub fn jse_last_error(rt: jse_runtime) -> *const c_char;

    /// Status code matching [`jse_last_error`], or [`JSE_OK`] if none.
    pub fn jse_last_error_code(rt: jse_runtime) -> c_int;

    /// Run pending promise jobs. `jse_eval` already drains before returning.
    pub fn jse_drain_microtasks(rt: jse_runtime);
}
