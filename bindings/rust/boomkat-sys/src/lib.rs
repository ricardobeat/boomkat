//! Raw, unmodified FFI declarations for `include/boomkat.h`.
//!
//! This crate is a 1:1 transcription of the C header and adds no safety of its
//! own. Every function here is `unsafe`. For an idiomatic API use the `boomkat`
//! crate, which wraps these.
//!
//! A runtime owns a heap; contexts are realms sharing its value registry.
//! Callback inputs borrow the active call, while returned handles transfer to
//! the engine. Eval and call leave jobs queued for host checkpoints.

#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_double, c_int, c_uint, c_ulonglong, c_void};

/// Opaque realm context.
pub type bk_ctx = *mut c_void;
pub type bk_runtime = *mut c_void;

/// Opaque value handle (64 bits). Not a pointer; 0 means failure.
pub type bk_value = c_ulonglong;

/// A host callback JS can invoke by name.
///
/// It must return normally in every case: `bk_throw_error` and `bk_throw`
/// record a throw rather than unwinding, and nothing may unwind across this
/// boundary.
pub type bk_c_function = unsafe extern "C" fn(
    ctx: bk_ctx,
    this_value: bk_value,
    argc: c_uint,
    argv: *const bk_value,
    udata: *mut c_void,
) -> bk_value;

/// One entry of a `bk_set_function_list` table. Mirrors `bk_fn_def` in the header;
/// field order and layout must match exactly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_fn_def {
    pub name: *const c_char,
    pub cfn: Option<bk_c_function>,
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
pub const BK_EXCEPTION: bk_value = 0;

// Immediate handles: valid with any context, never freed.
pub const BK_UNDEFINED: bk_value = 1;
pub const BK_NULL: bk_value = 2;
pub const BK_TRUE: bk_value = 3;
pub const BK_FALSE: bk_value = 4;

/// A string's units in place: width 1 is Latin-1, width 2 native UTF-16.
/// `ascii` is nonzero when width is 1 and every unit is below 0x80. Valid only
/// until the next call into the engine.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_string_view {
    pub data: *const c_void,
    pub length: usize,
    pub width: u8,
    pub ascii: u8,
}

/// Called once when an external string is freed, with its buffer and length in units.
pub type bk_string_release =
    unsafe extern "C" fn(opaque: *mut c_void, data: *const c_void, length: usize);

// Status codes. 0 is success; all errors are negative.
pub const BK_OK: c_int = 0;
/// Allocation failed.
pub const BK_ERR_NOMEM: c_int = -1;
/// Compile failed; see `bk_get_error_message`.
pub const BK_ERR_SYNTAX: c_int = -2;
/// Uncaught JS exception; see `bk_get_error_message`.
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
/// Invalid UTF-8 input, or a lone surrogate read in strict mode.
pub const BK_ERR_ENCODING: c_int = -9;
/// Feature compiled out of this build.
pub const BK_ERR_UNSUPPORTED: c_int = -10;

// `bk_utf8_mode` values for `bk_read_string_utf8`.
/// A lone surrogate becomes U+FFFD.
pub const BK_UTF8_REPLACE: c_int = 0;
/// A lone surrogate fails with `BK_ERR_ENCODING`.
pub const BK_UTF8_STRICT: c_int = 1;

// Value types as reported by `bk_get_type`.
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

#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_error_info {
    pub code: c_int,
    pub line: c_int,
    pub col: c_int,
    pub script_name: *const c_char,
}
pub type bk_interrupt_fn = unsafe extern "C" fn(bk_runtime, *mut c_void) -> c_int;
pub type bk_promise_rejection_fn =
    unsafe extern "C" fn(bk_ctx, u64, bk_value, bk_value, c_int, *mut c_void);
pub const BK_EVAL_GLOBAL: c_uint = 0;
pub const BK_EVAL_MODULE: c_uint = 1;
pub const BK_EVAL_STRICT: c_uint = 2;

extern "C" {
    pub fn bk_new_runtime() -> bk_runtime;
    pub fn bk_free_runtime(runtime: bk_runtime);
    pub fn bk_new_context(runtime: bk_runtime) -> bk_ctx;
    pub fn bk_free_context(ctx: bk_ctx);
    pub fn bk_get_runtime(ctx: bk_ctx) -> bk_runtime;
    pub fn bk_set_runtime_opaque(runtime: bk_runtime, opaque: *mut c_void);
    pub fn bk_get_runtime_opaque(runtime: bk_runtime) -> *mut c_void;
    pub fn bk_set_context_opaque(ctx: bk_ctx, opaque: *mut c_void);
    pub fn bk_get_context_opaque(ctx: bk_ctx) -> *mut c_void;
    pub fn bk_version() -> *const c_char;
    pub fn bk_eval_ex(
        ctx: bk_ctx,
        source: *const c_char,
        length: usize,
        filename: *const c_char,
        flags: c_uint,
    ) -> bk_value;
    pub fn bk_define_module(
        ctx: bk_ctx,
        name: *const c_char,
        name_len: usize,
        source: *const c_char,
        length: usize,
    ) -> c_int;
    pub fn bk_set_jsx(
        ctx: bk_ctx,
        enable: c_int,
        runtime: c_int,
        import_source: *const c_char,
        factory: *const c_char,
        fragment: *const c_char,
    ) -> c_int;
    pub fn bk_is_job_pending(runtime: bk_runtime) -> c_int;
    pub fn bk_execute_pending_job(runtime: bk_runtime, ctx: *mut bk_ctx) -> c_int;
    pub fn bk_run_jobs(runtime: bk_runtime) -> c_int;
    pub fn bk_free_value(ctx: bk_ctx, value: bk_value);
    pub fn bk_dup_value(ctx: bk_ctx, value: bk_value) -> bk_value;
    pub fn bk_get_exception(ctx: bk_ctx) -> bk_value;
    pub fn bk_get_error_message(ctx: bk_ctx) -> *const c_char;
    pub fn bk_get_error_code(ctx: bk_ctx) -> c_int;
    pub fn bk_get_error_info(ctx: bk_ctx, out: *mut bk_error_info) -> c_int;
    pub fn bk_status_str(status: c_int) -> *const c_char;
    pub fn bk_type_str(r#type: c_int) -> *const c_char;
    pub fn bk_get_type(ctx: bk_ctx, value: bk_value) -> c_int;
    pub fn bk_read_number(ctx: bk_ctx, value: bk_value, out: *mut c_double) -> c_int;
    pub fn bk_read_bool(ctx: bk_ctx, value: bk_value, out: *mut c_int) -> c_int;
    pub fn bk_read_string(
        ctx: bk_ctx,
        value: bk_value,
        buffer: *mut c_char,
        capacity: usize,
        length: *mut usize,
    ) -> c_int;
    pub fn bk_read_string_utf8(
        ctx: bk_ctx,
        value: bk_value,
        mode: c_int,
        buffer: *mut c_char,
        capacity: usize,
        length: *mut usize,
    ) -> c_int;
    pub fn bk_read_string_utf16(
        ctx: bk_ctx,
        value: bk_value,
        buffer: *mut u16,
        capacity: usize,
        length: *mut usize,
    ) -> c_int;
    pub fn bk_string_length(ctx: bk_ctx, value: bk_value) -> usize;
    pub fn bk_string_view_get(ctx: bk_ctx, value: bk_value, out: *mut bk_string_view) -> c_int;
    pub fn bk_to_number(ctx: bk_ctx, value: bk_value) -> c_double;
    pub fn bk_to_bool(ctx: bk_ctx, value: bk_value) -> c_int;
    pub fn bk_to_string(ctx: bk_ctx, value: bk_value) -> bk_value;
    pub fn bk_to_cstring(ctx: bk_ctx, value: bk_value, length: *mut usize) -> *const c_char;
    pub fn bk_free_cstring(ctx: bk_ctx, string: *const c_char);
    pub fn bk_new_number(ctx: bk_ctx, value: c_double) -> bk_value;
    pub fn bk_new_string(ctx: bk_ctx, utf8: *const c_char, length: usize) -> bk_value;
    pub fn bk_new_string_latin1(ctx: bk_ctx, chars: *const u8, length: usize) -> bk_value;
    pub fn bk_new_string_utf16(ctx: bk_ctx, units: *const u16, length: usize) -> bk_value;
    pub fn bk_new_external_string_latin1(
        ctx: bk_ctx,
        chars: *const u8,
        length: usize,
        release: Option<bk_string_release>,
        opaque: *mut c_void,
    ) -> bk_value;
    pub fn bk_new_external_string_utf16(
        ctx: bk_ctx,
        units: *const u16,
        length: usize,
        release: Option<bk_string_release>,
        opaque: *mut c_void,
    ) -> bk_value;
    pub fn bk_new_object(ctx: bk_ctx) -> bk_value;
    pub fn bk_new_array(ctx: bk_ctx) -> bk_value;
    pub fn bk_new_array_from(ctx: bk_ctx, elements: *const bk_value, count: c_uint) -> bk_value;
    pub fn bk_get_global_object(ctx: bk_ctx) -> bk_value;
    pub fn bk_get_property(
        ctx: bk_ctx,
        object: bk_value,
        key: *const c_char,
        key_len: usize,
    ) -> bk_value;
    pub fn bk_get_property_uint32(ctx: bk_ctx, object: bk_value, index: c_uint) -> bk_value;
    pub fn bk_set_property(
        ctx: bk_ctx,
        object: bk_value,
        key: *const c_char,
        key_len: usize,
        value: bk_value,
    ) -> c_int;
    pub fn bk_set_property_uint32(
        ctx: bk_ctx,
        object: bk_value,
        index: c_uint,
        value: bk_value,
    ) -> c_int;
    pub fn bk_has_property(
        ctx: bk_ctx,
        object: bk_value,
        key: *const c_char,
        key_len: usize,
        out: *mut c_int,
    ) -> c_int;
    pub fn bk_delete_property(
        ctx: bk_ctx,
        object: bk_value,
        key: *const c_char,
        key_len: usize,
        out: *mut c_int,
    ) -> c_int;
    pub fn bk_get_own_property_names(ctx: bk_ctx, object: bk_value) -> bk_value;
    pub fn bk_set_global_property(
        ctx: bk_ctx,
        name: *const c_char,
        length: usize,
        value: bk_value,
    ) -> c_int;
    pub fn bk_call(
        ctx: bk_ctx,
        function: bk_value,
        this_value: bk_value,
        argv: *const bk_value,
        argc: c_uint,
    ) -> bk_value;
    pub fn bk_new_c_function(
        ctx: bk_ctx,
        callback: Option<bk_c_function>,
        name: *const c_char,
        arity: c_int,
        flags: c_uint,
        opaque: *mut c_void,
    ) -> bk_value;
    pub fn bk_set_function_list(
        ctx: bk_ctx,
        target: bk_value,
        functions: *const bk_fn_def,
    ) -> c_int;
    pub fn bk_get_new_target(ctx: bk_ctx) -> bk_value;
    pub fn bk_is_constructor_call(ctx: bk_ctx) -> c_int;
    pub fn bk_throw_error(ctx: bk_ctx, kind: c_int, message: *const c_char) -> bk_value;
    pub fn bk_throw(ctx: bk_ctx, value: bk_value) -> bk_value;
    pub fn bk_set_promise_rejection_tracker(
        runtime: bk_runtime,
        callback: Option<bk_promise_rejection_fn>,
        opaque: *mut c_void,
    );
    pub fn bk_set_interrupt(
        runtime: bk_runtime,
        callback: Option<bk_interrupt_fn>,
        opaque: *mut c_void,
    );
    pub fn bk_request_interrupt(runtime: bk_runtime);
    pub fn bk_clear_interrupt(runtime: bk_runtime);
    pub fn bk_set_memory_limit(runtime: bk_runtime, bytes: u64);
}
