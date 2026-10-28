//! Raw, unmodified FFI declarations for `include/boomkat.h`.
//!
//! This crate is a 1:1 transcription of the C header and adds no safety of its
//! own. Every function here is `unsafe`. For an idiomatic API use the `boomkat`
//! crate, which wraps these.
//!
//! A runtime owns a heap; contexts are realms sharing its value registry.
//! Callback inputs borrow the active call, and values a callback creates are
//! locals of that call; the handle a callback returns is borrowed. Eval and call leave jobs queued for host checkpoints.

#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_double, c_int, c_uint, c_ulonglong, c_void};

/// Opaque realm context.
pub type bk_ctx = *mut c_void;
pub type bk_runtime = *mut c_void;

/// Opaque value handle (64 bits). Not a pointer; 0 means failure.
pub type bk_value = c_ulonglong;

/// A property key held by the runtime; 0 means failure.
pub type bk_atom = u32;

// `bk_get_own_property_keys` flags.
pub const BK_KEYS_OWN: c_uint = 0;
pub const BK_KEYS_STRINGS: c_uint = 1;
pub const BK_KEYS_SYMBOLS: c_uint = 2;
pub const BK_KEYS_ENUMERABLE_ONLY: c_uint = 4;
pub const BK_KEYS_SKIP_INDICES: c_uint = 8;

/// A local scope id; 0 means none.
pub type bk_scope = u32;

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
    pub finalize: Option<bk_finalizer>,
    pub finalize_opaque: *mut c_void,
}

/// Runs once with a C function's data when the function is freed, the runtime
/// is destroyed, or creation fails. It must not call the engine.
pub type bk_finalizer = unsafe extern "C" fn(data: *mut c_void, opaque: *mut c_void);

/// Storage for one JS value inside host memory; see `bk_trace_slot`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_slot {
    pub opaque: [u64; 2],
}
/// Opaque marker passed to trace callbacks.
#[repr(C)]
pub struct bk_tracer {
    _private: [u8; 0],
}
pub type bk_trace_fn = unsafe extern "C" fn(payload: *mut c_void, tracer: *mut bk_tracer, opaque: *mut c_void);
pub type bk_root_tracer = unsafe extern "C" fn(tracer: *mut bk_tracer, opaque: *mut c_void);

// Promise states for `bk_promise_state_get`.
pub const BK_PROMISE_PENDING: c_int = 0;
pub const BK_PROMISE_FULFILLED: c_int = 1;
pub const BK_PROMISE_REJECTED: c_int = 2;

/// Runs when a job is enqueued into an empty queue; must not run JS.
pub type bk_job_hook = unsafe extern "C" fn(runtime: bk_runtime, opaque: *mut c_void);

/// An engine-owned module question, valid during the loader callback.
#[repr(C)]
pub struct bk_module_request {
    _private: [u8; 0],
}
pub const BK_LOADER_ASYNC: c_uint = 1;
pub const BK_LOADER_NO_FILESYSTEM_FALLBACK: c_uint = 2;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_module_loader {
    pub resolve: Option<
        unsafe extern "C" fn(bk_ctx, *const c_char, *const c_char, *mut bk_module_request, *mut c_void) -> c_int,
    >,
    pub load: Option<unsafe extern "C" fn(bk_ctx, *const c_char, *mut bk_module_request, *mut c_void) -> c_int>,
    pub opaque: *mut c_void,
    pub flags: c_uint,
}

/// A host class id; 0 is invalid.
// bk_element_type
pub const BK_INT8: c_int = 0;
pub const BK_UINT8: c_int = 1;
pub const BK_UINT8_CLAMPED: c_int = 2;
pub const BK_INT16: c_int = 3;
pub const BK_UINT16: c_int = 4;
pub const BK_INT32: c_int = 5;
pub const BK_UINT32: c_int = 6;
pub const BK_FLOAT16: c_int = 7;
pub const BK_FLOAT32: c_int = 8;
pub const BK_FLOAT64: c_int = 9;
pub const BK_BIGINT64: c_int = 10;
pub const BK_BIGUINT64: c_int = 11;

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct bk_typed_array_info {
    pub type_: c_int,
    pub data: *mut c_void,
    pub length: usize,
    pub byte_offset: usize,
    pub buffer: bk_value,
}

pub type bk_weak = u64;

pub type bk_class = u32;
pub const BK_CLASS_DEFER_FINALIZE: c_uint = 1;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_class_def {
    pub name: *const c_char,
    pub parent: bk_class,
    pub finalize: Option<bk_finalizer>,
    pub trace: Option<bk_trace_fn>,
    pub construct: Option<bk_c_function>,
    pub arity: c_int,
    pub flags: c_uint,
    pub opaque: *mut c_void,
}

/// The all-zero entry that terminates a registration table.
pub const BK_FN_END: bk_fn_def = bk_fn_def {
    name: std::ptr::null(),
    cfn: None,
    arity: 0,
    flags: 0,
    udata: std::ptr::null_mut(),
    finalize: None,
    finalize_opaque: std::ptr::null_mut(),
};

/// Registration flag: `new fn()` is allowed; without it, it throws a TypeError.
pub const BK_CTOR: c_uint = 1;

/// Embedder data slots per runtime and per context; slot 3 is reserved.
pub const BK_DATA_SLOTS: c_uint = 4;

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
pub const BK_TYPE_SYMBOL: c_int = 7;
pub const BK_TYPE_BIGINT: c_int = 8;

// Error kinds for `bk_throw_error`.
pub const BK_ERROR: c_int = 0;
pub const BK_ERROR_TYPE: c_int = 1;
pub const BK_ERROR_RANGE: c_int = 2;
pub const BK_ERROR_REFERENCE: c_int = 3;
pub const BK_ERROR_SYNTAX: c_int = 4;

// Property descriptor flags.
pub const BK_PROP_WRITABLE: c_uint = 1;
pub const BK_PROP_ENUMERABLE: c_uint = 2;
pub const BK_PROP_CONFIGURABLE: c_uint = 4;
pub const BK_PROP_HAS_VALUE: c_uint = 8;
pub const BK_PROP_HAS_GET: c_uint = 16;
pub const BK_PROP_HAS_SET: c_uint = 32;
pub const BK_PROP_HAS_WRITABLE: c_uint = 64;
pub const BK_PROP_HAS_ENUMERABLE: c_uint = 128;
pub const BK_PROP_HAS_CONFIGURABLE: c_uint = 256;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_property_descriptor {
    pub flags: c_uint,
    pub value: bk_value,
    pub get: bk_value,
    pub set: bk_value,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_error_info {
    pub code: c_int,
    pub line: c_int,
    pub col: c_int,
    pub script_name: *const c_char,
    pub stack: *const c_char,
}
pub type bk_interrupt_fn = unsafe extern "C" fn(bk_runtime, *mut c_void) -> c_int;
pub type bk_promise_rejection_fn =
    unsafe extern "C" fn(bk_ctx, u64, bk_value, bk_value, c_int, *mut c_void);
/// Runtime options: an allocator set (all three functions or none) and a
/// fatal handler that must not return.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct bk_runtime_options {
    pub alloc: Option<unsafe extern "C" fn(opaque: *mut c_void, size: usize) -> *mut c_void>,
    pub realloc:
        Option<unsafe extern "C" fn(opaque: *mut c_void, ptr: *mut c_void, size: usize) -> *mut c_void>,
    pub free: Option<unsafe extern "C" fn(opaque: *mut c_void, ptr: *mut c_void)>,
    pub alloc_opaque: *mut c_void,
    pub fatal: Option<unsafe extern "C" fn(opaque: *mut c_void, message: *const c_char)>,
}
pub const BK_EVAL_GLOBAL: c_uint = 0;
pub const BK_EVAL_MODULE: c_uint = 1;
pub const BK_EVAL_STRICT: c_uint = 2;

extern "C" {
    pub fn bk_new_runtime(options: *const bk_runtime_options) -> bk_runtime;
    pub fn bk_alloc(runtime: bk_runtime, size: usize) -> *mut c_void;
    pub fn bk_realloc(runtime: bk_runtime, ptr: *mut c_void, size: usize) -> *mut c_void;
    pub fn bk_free_memory(runtime: bk_runtime, ptr: *mut c_void);
    pub fn bk_free_runtime(runtime: bk_runtime);
    pub fn bk_new_context(runtime: bk_runtime) -> bk_ctx;
    pub fn bk_free_context(ctx: bk_ctx);
    pub fn bk_get_runtime(ctx: bk_ctx) -> bk_runtime;
    pub fn bk_set_runtime_data(runtime: bk_runtime, slot: c_uint, data: *mut c_void);
    pub fn bk_get_runtime_data(runtime: bk_runtime, slot: c_uint) -> *mut c_void;
    pub fn bk_set_context_data(ctx: bk_ctx, slot: c_uint, data: *mut c_void);
    pub fn bk_get_context_data(ctx: bk_ctx, slot: c_uint) -> *mut c_void;
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
    pub fn bk_scope_open(ctx: bk_ctx) -> bk_scope;
    pub fn bk_scope_close(ctx: bk_ctx, scope: bk_scope);
    pub fn bk_scope_close_escape(ctx: bk_ctx, scope: bk_scope, value: bk_value) -> bk_value;
    pub fn bk_scope_local(ctx: bk_ctx, value: bk_value) -> bk_value;
    pub fn bk_scope_current(ctx: bk_ctx) -> bk_scope;
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
    pub fn bk_get_own_property_keys(ctx: bk_ctx, object: bk_value, flags: c_uint) -> bk_value;
    pub fn bk_new_atom(ctx: bk_ctx, utf8: *const c_char, length: usize) -> bk_atom;
    pub fn bk_new_atom_index(ctx: bk_ctx, index: u32) -> bk_atom;
    pub fn bk_value_to_atom(ctx: bk_ctx, key: bk_value) -> bk_atom;
    pub fn bk_atom_to_value(ctx: bk_ctx, atom: bk_atom) -> bk_value;
    pub fn bk_dup_atom(ctx: bk_ctx, atom: bk_atom) -> bk_atom;
    pub fn bk_free_atom(ctx: bk_ctx, atom: bk_atom);
    pub fn bk_get_property_atom(ctx: bk_ctx, object: bk_value, key: bk_atom) -> bk_value;
    pub fn bk_set_property_atom(ctx: bk_ctx, object: bk_value, key: bk_atom, value: bk_value) -> c_int;
    pub fn bk_has_property_atom(ctx: bk_ctx, object: bk_value, key: bk_atom, out: *mut c_int) -> c_int;
    pub fn bk_delete_property_atom(ctx: bk_ctx, object: bk_value, key: bk_atom, out: *mut c_int) -> c_int;
    pub fn bk_define_property(
        ctx: bk_ctx,
        object: bk_value,
        key: bk_atom,
        desc: *const bk_property_descriptor,
        ok: *mut c_int,
    ) -> c_int;
    pub fn bk_get_own_property(
        ctx: bk_ctx,
        object: bk_value,
        key: bk_atom,
        out: *mut bk_property_descriptor,
        found: *mut c_int,
    ) -> c_int;
    pub fn bk_set_global_property(
        ctx: bk_ctx,
        name: *const c_char,
        length: usize,
        value: bk_value,
    ) -> c_int;
    pub fn bk_construct(
        ctx: bk_ctx,
        constructor: bk_value,
        argv: *const bk_value,
        argc: c_uint,
        new_target: bk_value,
    ) -> bk_value;
    pub fn bk_new_object_with_proto(ctx: bk_ctx, proto: bk_value) -> bk_value;
    pub fn bk_get_prototype(ctx: bk_ctx, object: bk_value) -> bk_value;
    pub fn bk_set_prototype(ctx: bk_ctx, object: bk_value, proto: bk_value) -> c_int;
    pub fn bk_instanceof(ctx: bk_ctx, value: bk_value, constructor: bk_value, out: *mut c_int) -> c_int;
    pub fn bk_strict_equals(ctx: bk_ctx, a: bk_value, b: bk_value) -> c_int;
    pub fn bk_same_value(ctx: bk_ctx, a: bk_value, b: bk_value) -> c_int;
    pub fn bk_is_array(ctx: bk_ctx, value: bk_value) -> c_int;
    pub fn bk_get_length(ctx: bk_ctx, object: bk_value, out: *mut u64) -> c_int;
    pub fn bk_json_parse(ctx: bk_ctx, utf8: *const c_char, length: usize) -> bk_value;
    pub fn bk_json_stringify(ctx: bk_ctx, value: bk_value) -> bk_value;
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
        data: *mut c_void,
        finalize: Option<bk_finalizer>,
        finalize_opaque: *mut c_void,
    ) -> bk_value;
    pub fn bk_define_class(
        ctx: bk_ctx,
        def: *const bk_class_def,
        constructor_out: *mut bk_value,
        prototype_out: *mut bk_value,
    ) -> bk_class;
    pub fn bk_new_instance(ctx: bk_ctx, cls: bk_class, payload: *mut c_void, new_target: bk_value) -> bk_value;
    pub fn bk_get_instance_payload(ctx: bk_ctx, value: bk_value, cls: bk_class) -> *mut c_void;
    pub fn bk_set_instance_payload(ctx: bk_ctx, value: bk_value, cls: bk_class, payload: *mut c_void) -> c_int;
    pub fn bk_get_instance_class(ctx: bk_ctx, value: bk_value) -> bk_class;
    pub fn bk_run_finalizers(runtime: bk_runtime) -> c_uint;
    pub fn bk_get_intrinsic(ctx: bk_ctx, which: c_int) -> bk_value;
    pub fn bk_new_symbol(ctx: bk_ctx, description: *const c_char, length: usize) -> bk_value;
    pub fn bk_symbol_for(ctx: bk_ctx, key: *const c_char, length: usize) -> bk_value;
    pub fn bk_get_well_known_symbol(ctx: bk_ctx, which: c_int) -> bk_value;
    pub fn bk_symbol_description(ctx: bk_ctx, symbol: bk_value) -> bk_value;
    pub fn bk_new_bigint_int64(ctx: bk_ctx, value: i64) -> bk_value;
    pub fn bk_new_bigint_uint64(ctx: bk_ctx, value: u64) -> bk_value;
    pub fn bk_read_bigint_int64(ctx: bk_ctx, value: bk_value, out: *mut i64, lossless: *mut c_int) -> c_int;
    pub fn bk_new_bigint_words(ctx: bk_ctx, negative: c_int, words: *const u64, count: usize) -> bk_value;
    pub fn bk_read_bigint_words(
        ctx: bk_ctx,
        value: bk_value,
        negative: *mut c_int,
        words: *mut u64,
        capacity: usize,
        count: *mut usize,
    ) -> c_int;
    pub fn bk_new_promise(ctx: bk_ctx, resolve_out: *mut bk_value, reject_out: *mut bk_value) -> bk_value;
    pub fn bk_promise_state_get(ctx: bk_ctx, promise: bk_value, out: *mut c_int) -> c_int;
    pub fn bk_promise_result(ctx: bk_ctx, promise: bk_value) -> bk_value;
    pub fn bk_promise_mark_handled(ctx: bk_ctx, promise: bk_value) -> c_int;
    pub fn bk_promise_resolve(ctx: bk_ctx, value: bk_value) -> bk_value;
    pub fn bk_promise_then(ctx: bk_ctx, promise: bk_value, on_fulfilled: bk_value, on_rejected: bk_value) -> bk_value;
    pub fn bk_set_module_loader(runtime: bk_runtime, loader: *const bk_module_loader) -> c_int;
    pub fn bk_module_set_name(request: *mut bk_module_request, name: *const c_char, length: usize) -> c_int;
    pub fn bk_module_provide(request: *mut bk_module_request, source: *const c_char, length: usize) -> c_int;
    pub fn bk_module_provide_native(request: *mut bk_module_request, exports: bk_value) -> c_int;
    pub fn bk_module_fail(request: *mut bk_module_request, error: bk_value) -> c_int;
    pub fn bk_define_native_module(ctx: bk_ctx, name: *const c_char, length: usize, exports: bk_value) -> c_int;
    pub fn bk_invalidate_module(ctx: bk_ctx, name: *const c_char, length: usize) -> c_int;
    pub fn bk_import(ctx: bk_ctx, specifier: *const c_char, length: usize) -> bk_value;
    pub fn bk_compile(
        ctx: bk_ctx,
        source: *const c_char,
        length: usize,
        filename: *const c_char,
        flags: c_uint,
    ) -> bk_value;
    pub fn bk_run_script(ctx: bk_ctx, script: bk_value) -> bk_value;
    pub fn bk_new_array_buffer(ctx: bk_ctx, length: usize, data_out: *mut *mut c_void) -> bk_value;
    pub fn bk_new_external_array_buffer(
        ctx: bk_ctx,
        data: *mut c_void,
        length: usize,
        release: Option<bk_finalizer>,
        opaque: *mut c_void,
    ) -> bk_value;
    pub fn bk_get_array_buffer(ctx: bk_ctx, buffer: bk_value, data: *mut *mut c_void, length: *mut usize) -> c_int;
    pub fn bk_detach_array_buffer(ctx: bk_ctx, buffer: bk_value) -> c_int;
    pub fn bk_new_typed_array(ctx: bk_ctx, type_: c_int, buffer: bk_value, byte_offset: usize, length: usize) -> bk_value;
    pub fn bk_get_typed_array(ctx: bk_ctx, view: bk_value, out: *mut bk_typed_array_info) -> c_int;
    pub fn bk_new_shared_array_buffer(ctx: bk_ctx, length: usize, data_out: *mut *mut c_void) -> bk_value;
    pub fn bk_adopt_shared_block(ctx: bk_ctx, data: *mut c_void) -> bk_value;
    pub fn bk_shared_block_retain(data: *mut c_void);
    pub fn bk_shared_block_release(data: *mut c_void);
    pub fn bk_new_weak(ctx: bk_ctx, target: bk_value) -> bk_weak;
    pub fn bk_weak_get(ctx: bk_ctx, weak: bk_weak) -> bk_value;
    pub fn bk_free_weak(ctx: bk_ctx, weak: bk_weak);
    pub fn bk_set_job_hook(runtime: bk_runtime, hook: Option<bk_job_hook>, opaque: *mut c_void);
    pub fn bk_wait_events(runtime: bk_runtime, timeout_ms: f64) -> c_int;
    pub fn bk_wake(runtime: bk_runtime);
    pub fn bk_slot_init(slot: *mut bk_slot);
    pub fn bk_slot_set(ctx: bk_ctx, slot: *mut bk_slot, value: bk_value) -> c_int;
    pub fn bk_slot_get(ctx: bk_ctx, slot: *const bk_slot) -> bk_value;
    pub fn bk_slot_clear(ctx: bk_ctx, slot: *mut bk_slot);
    pub fn bk_trace_slot(tracer: *mut bk_tracer, slot: *const bk_slot);
    pub fn bk_set_root_tracer(runtime: bk_runtime, callback: Option<bk_root_tracer>, opaque: *mut c_void);
    pub fn bk_set_function_list(
        ctx: bk_ctx,
        target: bk_value,
        functions: *const bk_fn_def,
    ) -> c_int;
    pub fn bk_get_new_target(ctx: bk_ctx) -> bk_value;
    pub fn bk_is_constructor_call(ctx: bk_ctx) -> c_int;
    pub fn bk_throw_error(ctx: bk_ctx, kind: c_int, message: *const c_char) -> bk_value;
    pub fn bk_throw(ctx: bk_ctx, value: bk_value) -> bk_value;
    pub fn bk_new_error(ctx: bk_ctx, kind: c_int, message: *const c_char) -> bk_value;
    pub fn bk_describe(
        ctx: bk_ctx,
        value: bk_value,
        buffer: *mut c_char,
        capacity: usize,
        length: *mut usize,
    ) -> c_int;
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
