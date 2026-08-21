module boomkat::capi;

import boomkat::builtins;
import boomkat::embed;
import boomkat::vm;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;

// ============================================================================
// The bk_ C ABI.
//
// This file is the C-facing face of `boomkat::embed`: it marshals to integer
// handles, status codes and out-parameters, and owns nothing. The registry,
// the error formatter, the UTF-8 sink and the host trampoline all live in
// `src/embed.c3`, shared with the native C3 binding in `bindings/c3`.
// ============================================================================

alias Runtime   = embed::Runtime;
alias SlotEntry = embed::SlotEntry;

// Status and type codes are declared once in `boomkat::embed` and re-exported
// here so the ABI code below reads as it always did. `include/boomkat.h`
// mirrors the same values.
const int BK_OK            = embed::BK_OK;
const int BK_ERR_NOMEM     = embed::BK_ERR_NOMEM;
const int BK_ERR_SYNTAX    = embed::BK_ERR_SYNTAX;
const int BK_ERR_THROW     = embed::BK_ERR_THROW;
const int BK_ERR_INTERNAL  = embed::BK_ERR_INTERNAL;
const int BK_ERR_INVALID   = embed::BK_ERR_INVALID;
const int BK_ERR_TYPE      = embed::BK_ERR_TYPE;
const int BK_ERR_FULL      = embed::BK_ERR_FULL;
const int BK_ERR_INTERRUPT = embed::BK_ERR_INTERRUPT;

const int BK_TYPE_UNDEFINED = embed::BK_TYPE_UNDEFINED;
const int BK_TYPE_NULL      = embed::BK_TYPE_NULL;
const int BK_TYPE_BOOLEAN   = embed::BK_TYPE_BOOLEAN;
const int BK_TYPE_NUMBER    = embed::BK_TYPE_NUMBER;
const int BK_TYPE_STRING    = embed::BK_TYPE_STRING;
const int BK_TYPE_OBJECT    = embed::BK_TYPE_OBJECT;
const int BK_TYPE_FUNCTION  = embed::BK_TYPE_FUNCTION;
const int BK_TYPE_OTHER     = embed::BK_TYPE_OTHER;

const usz ERRBUF = embed::ERRBUF;

// ============================================================================
// Lifecycle
// ============================================================================

// Create a runtime and store it in *out_rt.
fn int bk_open(void** out_rt) @export("bk_open") {
    if (out_rt == null) return BK_ERR_INVALID;
    Runtime* rt = embed::create();
    *out_rt = (void*)rt;
    return rt == null ? BK_ERR_NOMEM : BK_OK;
}

// Destroy the runtime and everything it owns. All outstanding handles become
// invalid. Safe with null.
fn void bk_close(void* rtp) @export("bk_close") {
    embed::destroy((Runtime*)rtp);
}

// Release a handle. Safe with 0, a scope handle, or an already-freed handle.
fn void bk_value_free(void* rtp, ulong id) @export("bk_value_free") {
    if (rtp == null) return;
    embed::slot_release((Runtime*)rtp, id);
}

// ============================================================================
// Eval
// ============================================================================

fn int bk_eval_with_name(void* rtp, char* src, usz len, char* name, usz name_len,
                              ulong* out_val) @export("bk_eval_with_name") {
    if (rtp == null || src == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    if (out_val != null) *out_val = 0;

    TVal res;
    int rc = embed::eval_source(rt, src[:len],
                                name != null ? name[:name_len] : (char[])"<eval>", &res);
    if (rc != BK_OK) return rc;

    // capi_store reports exhaustion for every value kind, undefined included:
    // letting an undefined result through as handle 0 would turn a failed
    // registration into an ordinary undefined -- a silent wrong answer.
    if (out_val != null) return capi_store(rt, res, out_val);
    return BK_OK;
}

/// The plain eval, fixed script name "<eval>". Forwards to the named variant,
/// so the position-bearing path is shared.
fn int bk_eval(void* rtp, char* src, usz len, ulong* out_val) @export("bk_eval") {
    return bk_eval_with_name(rtp, src, len, "<eval>", 6, out_val);
}


// ============================================================================
// Readers
// ============================================================================

fn int type_of(Runtime* rt, void* ctxp, ulong id) {
    if (rt == null) return BK_TYPE_OTHER;
    TVal v;
    if (!embed::resolve_handle(rt, ctxp, id, &v)) return BK_TYPE_UNDEFINED;
    return embed::classify(v);
}

fn int bk_type_of(void* rtp, ulong id) @export("bk_type_of") {
    return type_of((Runtime*)rtp, null, id);
}

/// Context tier; see bk_ctx_get_number.
fn int bk_ctx_type_of(void* ctxp, ulong id) @export("bk_ctx_type_of") {
    return type_of(embed::ctx_runtime(ctxp), ctxp, id);
}

// A reader that fails must leave a message behind: bk_last_error is documented
// as describing "the most recent failure", and a host that logs it on a bad
// status would otherwise print an empty string (or, worse, a stale message from
// an unrelated earlier call).
fn int reader_fail(Runtime* rt, int code, String msg) {
    embed::set_err(rt, code, msg);
    return code;
}

// The readers come in two tiers. A host function holds a call context, not a
// runtime, and only the context tier can resolve a scope handle at all. Code
// outside a callback holds a runtime and uses the runtime tier. Neither accepts
// a null and falls back to "the one runtime": a global slot handle is an index
// into some runtime's registry, so with two runtimes open there is no such
// thing, and guessing would resolve one runtime's handle against another's
// values.
fn int read_number(Runtime* rt, void* ctxp, ulong id, double* out) {
    if (out == null) return BK_ERR_INVALID;
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!embed::resolve_handle(rt, ctxp, id, &v)) return reader_fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_numeric()) return reader_fail(rt, BK_ERR_TYPE, "value is not a number");
    *out = v.get_number_or_fastint();
    return BK_OK;
}

fn int bk_get_number(void* rtp_in, ulong id, double* out) @export("bk_get_number") {
    return read_number((Runtime*)rtp_in, null, id, out);
}

/// Context tier: reads an argument or any handle a callback holds, including a
/// scope handle, which the runtime tier cannot resolve.
fn int bk_ctx_get_number(void* ctxp, ulong id, double* out) @export("bk_ctx_get_number") {
    return read_number(embed::ctx_runtime(ctxp), ctxp, id, out);
}

fn int read_bool(Runtime* rt, void* ctxp, ulong id, int* out) {
    if (out == null) return BK_ERR_INVALID;
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!embed::resolve_handle(rt, ctxp, id, &v)) return reader_fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_boolean()) return reader_fail(rt, BK_ERR_TYPE, "value is not a boolean");
    *out = v.get_boolean() ? 1 : 0;
    return BK_OK;
}

fn int bk_get_bool(void* rtp_in, ulong id, int* out) @export("bk_get_bool") {
    return read_bool((Runtime*)rtp_in, null, id, out);
}

/// Context tier; see bk_ctx_get_number.
fn int bk_ctx_get_bool(void* ctxp, ulong id, int* out) @export("bk_ctx_get_bool") {
    return read_bool(embed::ctx_runtime(ctxp), ctxp, id, out);
}


/// Copy a JS string out as NUL-terminated UTF-8. Two-call protocol: pass
/// buf==null to learn the required size (excluding NUL).
fn int read_string(Runtime* rt, void* ctxp, ulong id, char* buf, usz cap, usz* out_len) {
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!embed::resolve_handle(rt, ctxp, id, &v)) return reader_fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_string()) return reader_fail(rt, BK_ERR_TYPE, "value is not a string");
    HString* hs = (HString*)v.get_heapptr();
    // Symbols share the string tag but carry no meaningful text; copying their
    // bytes out would yield invalid UTF-8. JS forbids implicit conversion too.
    if (hs != null && hs.is_symbol()) return BK_ERR_TYPE;

    usz need = embed::utf8_write(hs, buf, buf == null ? 0 : cap);
    if (out_len != null) *out_len = need;
    if (buf == null) return BK_OK;
    if (need + 1 > cap) return reader_fail(rt, BK_ERR_FULL, "buffer too small for string");
    buf[need] = 0;
    return BK_OK;
}

fn int bk_get_string(void* rtp_in, ulong id, char* buf, usz cap, usz* out_len) @export("bk_get_string") {
    return read_string((Runtime*)rtp_in, null, id, buf, cap, out_len);
}

/// Context tier; see bk_ctx_get_number.
fn int bk_ctx_get_string(void* ctxp, ulong id, char* buf, usz cap, usz* out_len) @export("bk_ctx_get_string") {
    return read_string(embed::ctx_runtime(ctxp), ctxp, id, buf, cap, out_len);
}

/// The runtime owning a callback's context, for a host that needs to persist a
/// value or evaluate. Mirrors QuickJS's JS_GetRuntime(ctx).
fn void* bk_ctx_runtime(void* ctxp) @export("bk_ctx_runtime") {
    return (void*)embed::ctx_runtime(ctxp);
}

// ============================================================================
// Errors / microtasks
// ============================================================================

fn char* bk_last_error(void* rtp) @export("bk_last_error") {
    if (rtp == null) return null;
    Runtime* rt = (Runtime*)rtp;
    return &rt.errmsg[0];
}

fn int bk_last_error_code(void* rtp) @export("bk_last_error_code") {
    if (rtp == null) return BK_ERR_INVALID;
    return ((Runtime*)rtp).errcode;
}

/// Layout must match bk_error_info in include/boomkat.h on the target's ABI.
struct BkErrorInfo {
    int code;
    int line;
    int col;
    char* script_name;
}

/// Fill *out with the most recent failure's kind and position. script_name
/// points at runtime-owned storage with the same lifetime as bk_last_error.
fn int bk_last_error_info(void* rtp, BkErrorInfo* out) @export("bk_last_error_info") {
    if (out == null) return BK_ERR_INVALID;
    if (rtp == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    out.code = rt.errcode;
    out.line = rt.err_line;
    out.col = rt.err_col;
    out.script_name = rt.err_name[0] != 0 ? &rt.err_name[0] : null;
    return BK_OK;
}

fn int bk_drain_microtasks(void* rtp) @export("bk_drain_microtasks") {
    if (rtp == null) return BK_ERR_INVALID;
    return embed::drain_microtasks((Runtime*)rtp);
}

/// Install, replace, or clear the interrupt handler. The callback runs on the
/// engine thread at VM safepoints; it must not call back into the engine. A
/// host interrupting from another thread sets a flag in `opaque` and returns
/// it here.
fn void bk_set_interrupt_handler(void* rtp, void* cb, void* opaque) @export("bk_set_interrupt_handler") {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    rt.heap.capi_interrupt_fn = cb;
    rt.heap.capi_interrupt_opaque = opaque;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
}

fn char* bk_version() @export("bk_version") {
    return "0.2.0";
}

// ============================================================================
// Host functions
//
// A host callback is a C function the engine calls when JS invokes the
// corresponding function value. The engine side (builtins::dispatch_host)
// stages a per-call scope; everything here is the opaque-handle layer over it.
//
// Handles inside a callback are SCOPE handles: they carry the high bit and are
// valid only for the duration of that call. bk_value_persist copies one into
// the global slot registry when the host needs it to outlive the callback.
// ============================================================================


/// Register `cfn` as a global function named `name`.
///
/// Returns BK_OK, or BK_ERR_INVALID / BK_ERR_NOMEM. The binding is created
/// on the global environment, so JS reaches it by bare name.
fn int bk_register_fn(void* rtp, char* name, usz name_len, void* cfn, void* udata,
                       int arity, int constructable) @export("bk_register_fn") {
    if (rtp == null || name == null || cfn == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    return embed::register_host_fn(rt, name[:name_len], cfn, udata, arity, constructable != 0);
}

// --- inside a callback ------------------------------------------------------

fn uint bk_argc(void* ctxp) @export("bk_argc") {
    if (ctxp == null) return 0;
    return builtins::host_argc((builtins::BuiltinContext*)ctxp);
}

/// Handle to argument `i`. Out-of-range yields a handle to undefined, matching
/// JS semantics and sparing every host an arity check.
fn ulong bk_arg(void* ctxp, uint i) @export("bk_arg") {
    return embed::scope_handle(embed::ctx_runtime(ctxp), (ulong)(heap::HOST_SCOPE_ARG0 + i));
}

fn ulong bk_this(void* ctxp) @export("bk_this") {
    return embed::scope_handle(embed::ctx_runtime(ctxp), (ulong)heap::HOST_SCOPE_THIS);
}

fn ulong bk_new_target(void* ctxp) @export("bk_new_target") {
    return embed::scope_handle(embed::ctx_runtime(ctxp), (ulong)heap::HOST_SCOPE_NEW_TARGET);
}

fn int bk_is_construct(void* ctxp) @export("bk_is_construct") {
    if (ctxp == null) return 0;
    return builtins::host_is_construct((builtins::BuiltinContext*)ctxp) ? 1 : 0;
}


/// Set the callback's return value from a handle.
fn void bk_return(void* ctxp, ulong id) @export("bk_return") {
    Runtime* rt = embed::ctx_runtime(ctxp);
    if (rt == null) return;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    TVal v;
    if (!embed::resolve_handle(rt, ctxp, id, &v)) return;
    builtins::host_return(ctx, v);
}

fn void bk_return_number(void* ctxp, double d) @export("bk_return_number") {
    if (ctxp == null) return;
    TVal v;
    v.set_number(d);
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

fn void bk_return_bool(void* ctxp, int b) @export("bk_return_bool") {
    if (ctxp == null) return;
    TVal v;
    v.set_boolean(b != 0);
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

fn void bk_return_null(void* ctxp) @export("bk_return_null") {
    if (ctxp == null) return;
    TVal v;
    v.set_null();
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

/// Set the return value to a fresh JS string built from UTF-8 bytes.
fn void bk_return_string(void* ctxp, char* utf8, usz len) @export("bk_return_string") {
    if (ctxp == null || utf8 == null) return;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    builtins::host_return(ctx, builtins::host_new_string(ctx, utf8[:len]));
}

/// Throw a fresh Error of `kind` with `msg`. Does not unwind: the callback
/// must still return normally, and the throw beats any return value set.
fn void bk_throw_error(void* ctxp, int kind, char* msg) @export("bk_throw_error") {
    if (ctxp == null || msg == null) return;
    usz n = 0;
    while (msg[n] != 0) n++;
    builtins::host_throw_error((builtins::BuiltinContext*)ctxp, kind, msg[:n]);
}

/// Throw an arbitrary value by handle.
fn void bk_throw(void* ctxp, ulong id) @export("bk_throw") {
    Runtime* rt = embed::ctx_runtime(ctxp);
    if (rt == null) return;
    TVal v;
    if (!embed::resolve_handle(rt, ctxp, id, &v)) return;
    builtins::host_throw((builtins::BuiltinContext*)ctxp, v);
}

/// Promote a scope handle to a runtime-owned global handle the host may keep
/// past the callback. The caller then owns it and must bk_value_free it.
fn ulong bk_value_persist(void* ctxp, ulong id) @export("bk_value_persist") {
    Runtime* rt = embed::ctx_runtime(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!embed::resolve_handle(rt, ctxp, id, &v)) return 0;
    return embed::slot_alloc(rt, v);
}

/// Call a JS function from host code.
///
/// `argv` is an array of `argc` handles. On success stores a scope-independent
/// global handle in *out_val (caller owns it) and returns BK_OK. On an
/// exception in the callee the throw is staged on the context, so the host
/// should return promptly; the status is BK_ERR_THROW.
fn int bk_call(void* ctxp, ulong func_id, ulong* argv, uint argc, ulong this_id,
                ulong* out_val) @export("bk_call") {
    Runtime* rt = embed::ctx_runtime(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    if (out_val != null) *out_val = 0;

    TVal fv;
    if (!embed::resolve_handle(rt, ctxp, func_id, &fv)) return BK_ERR_INVALID;
    TVal tv;
    if (this_id == 0) { tv.set_undefined(); } else if (!embed::resolve_handle(rt, ctxp, this_id, &tv)) { tv.set_undefined(); }

    // Bounded stack array: the engine's own call paths cap staged arguments
    // the same way, and a host needing more can build an array in JS.
    TVal[16] args;
    uint n = argc > 16 ? 16 : argc;
    for (uint i = 0; i < n; i++) {
        TVal a;
        if (argv == null || !embed::resolve_handle(rt, ctxp, argv[i], &a)) a.set_undefined();
        args[i] = a;
    }

    bool ok = false;
    TVal res = builtins::host_call(ctx, fv, &args[0], n, tv, &ok);
    if (!ok) {
        // An interrupt heard here stays flagged: the staged re-throw that
        // fires when this callback returns must remain uncatchable, so the
        // flag clears only at the outermost host boundary that surfaces it.
        if (rt.heap.uncatchable_throw) {
            embed::set_err(rt, BK_ERR_INTERRUPT, "interrupted");
            return BK_ERR_INTERRUPT;
        }
        return BK_ERR_THROW;
    }
    if (out_val != null) {
        // Report exhaustion for every value kind, undefined included: handle 0
        // reads back as undefined, so returning it on a failed registration
        // would be a silent wrong answer rather than an error.
        ulong id = embed::slot_alloc(rt, res);
        if (id == 0) {
            embed::set_err(rt, BK_ERR_FULL, "value slot table full");
            return BK_ERR_FULL;
        }
        *out_val = id;
    }
    return BK_OK;
}

// ============================================================================
// Value construction, object graph, and host calls outside a callback
// ============================================================================
//
// These mirror the bk_return_* / bk_call helpers but live on the runtime
// tier, for hosts that hold a bk_runtime (or a context promoted out of a
// callback) rather than a live call context. Handles they return are
// caller-owned and must be bk_value_free'd, like bk_eval results.

/// Allocate a slot for `v`, reporting a full table explicitly.
fn int capi_store(Runtime* rt, TVal v, ulong* out) {
    ulong id = embed::slot_alloc(rt, v);
    if (id == 0) { embed::set_err(rt, BK_ERR_FULL, "value slot table full"); return BK_ERR_FULL; }
    *out = id;
    return BK_OK;
}

fn int bk_new_number(void* rtp, double d, ulong* out) @export("bk_new_number") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal v; v.set_number(d);
    return capi_store(rt, v, out);
}

fn int bk_new_bool(void* rtp, int b, ulong* out) @export("bk_new_bool") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal v; v.set_boolean(b != 0);
    return capi_store(rt, v, out);
}

fn int bk_new_null(void* rtp, ulong* out) @export("bk_new_null") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal v; v.set_null();
    return capi_store(rt, v, out);
}

fn int bk_new_undefined(void* rtp, ulong* out) @export("bk_new_undefined") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal v; v.set_undefined();
    return capi_store(rt, v, out);
}

fn int bk_new_string(void* rtp, char* utf8, usz len, ulong* out) @export("bk_new_string") {
    if (rtp == null || utf8 == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    HString* s = rt.heap.str_intern(utf8[:len]);
    if (s == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    TVal v; v.set_string(s);
    return capi_store(rt, v, out);
}

fn int bk_new_object(void* rtp, ulong* out) @export("bk_new_object") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    HObject*? oraw = rt.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch oraw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    HObject* o = oraw;
    o.prototype = rt.heap.object_proto;
    TVal v; v.set_object(o);
    return capi_store(rt, v, out);
}

fn int bk_new_array(void* rtp, ulong* out) @export("bk_new_array") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    HObject*? araw = rt.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch araw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    HObject* a = araw;
    a.prototype = rt.heap.array_proto;
    TVal v; v.set_object(a);
    return capi_store(rt, v, out);
}

/// Fresh array whose elements are the first `n` of `elems`. The caller keeps
/// ownership of the input handles; they are copied in.
fn int bk_new_array_from(void* rtp, ulong* elems, uint n, ulong* out) @export("bk_new_array_from") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    if (n > 0 && elems == null) return BK_ERR_INVALID;
    HObject*? araw = rt.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch araw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    HObject* a = araw;
    a.prototype = rt.heap.array_proto;
    for (uint i = 0; i < n; i++) {
        TVal ev;
        if (elems == null || !embed::slot_get(rt, elems[i], &ev)) ev.set_undefined();
        builtins::array_set_elem(a, i, ev, rt.heap);
    }
    TVal len_tv; len_tv.set_fastint((long)n);
    a.put_prop(rt.heap.str(heap::BuiltinStr.LENGTH), len_tv, hobject::PROP_FLAGS_WEC, rt.heap);
    TVal v; v.set_object(a);
    return capi_store(rt, v, out);
}

/// Handle to the global object (globalThis). Caller owns it.
fn int bk_get_global(void* rtp, ulong* out) @export("bk_get_global") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal g;
    if (rt.vm.global_env != null && rt.vm.global_env.bindings != null) {
        g.set_object(rt.vm.global_env.bindings);
    } else {
        g.set_undefined();
    }
    return capi_store(rt, g, out);
}

/// Resolve a property handle to an HObject, or fail with BK_ERR_TYPE.
fn HObject* capi_object(Runtime* rt, ulong id, TVal* out) {
    if (!embed::slot_get(rt, id, out)) return null;
    if (!out.is_object()) return null;
    return (HObject*)out.get_heapptr();
}

/// Surface a VM failure (heap error channel) as a bk_ status, distinguishing an
/// interrupt from an ordinary throw.
fn int capi_vm_fault(Runtime* rt) {
    if (rt.heap.uncatchable_throw) {
        rt.heap.uncatchable_throw = false;
        embed::set_err(rt, BK_ERR_INTERRUPT, "interrupted");
        return BK_ERR_INTERRUPT;
    }
    embed::describe_error(rt, &rt.heap.error_value);
    return BK_ERR_THROW;
}

fn int bk_get_prop(void* rtp, ulong obj_id, char* key, usz key_len, ulong* out) @export("bk_get_prop") {
    if (rtp == null || key == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    *out = 0;
    TVal ov;
    if (capi_object(rt, obj_id, &ov) == null) return reader_fail(rt, BK_ERR_TYPE, "value is not an object");
    HObject* obj = (HObject*)ov.get_heapptr();
    HString* k = rt.heap.str_intern(key[:key_len]);
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    TVal got;
    if (!builtins::js_get_with_receiver((void*)rt.vm, rt.heap, obj, k, ov, &got)) {
        return capi_vm_fault(rt);
    }
    return capi_store(rt, got, out);
}

fn int bk_get_prop_index(void* rtp, ulong obj_id, uint idx, ulong* out) @export("bk_get_prop_index") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    *out = 0;
    TVal ov;
    if (capi_object(rt, obj_id, &ov) == null) return reader_fail(rt, BK_ERR_TYPE, "value is not an object");
    HObject* obj = (HObject*)ov.get_heapptr();
    HString* k = rt.heap.int_to_hstring((long)idx);
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    TVal got;
    if (!builtins::js_get_with_receiver((void*)rt.vm, rt.heap, obj, k, ov, &got)) {
        return capi_vm_fault(rt);
    }
    return capi_store(rt, got, out);
}

fn int bk_set_prop(void* rtp, ulong obj_id, char* key, usz key_len, ulong val_id) @export("bk_set_prop") {
    if (rtp == null || key == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal ov, vv;
    if (capi_object(rt, obj_id, &ov) == null) return reader_fail(rt, BK_ERR_TYPE, "value is not an object");
    if (!embed::slot_get(rt, val_id, &vv)) return reader_fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    HObject* obj = (HObject*)ov.get_heapptr();
    HString* k = rt.heap.str_intern(key[:key_len]);
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    bool res;
    if (!builtins::js_set_with_receiver((void*)rt.vm, rt.heap, obj, k, vv, ov, &res)) {
        return capi_vm_fault(rt);
    }
    if (!res) {
        // Strict-only engine: a Set that returns false throws a TypeError.
        embed::set_err(rt, BK_ERR_THROW, "Cannot assign to read only property");
        return BK_ERR_THROW;
    }
    return BK_OK;
}

fn int bk_set_prop_index(void* rtp, ulong obj_id, uint idx, ulong val_id) @export("bk_set_prop_index") {
    if (rtp == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal ov, vv;
    if (capi_object(rt, obj_id, &ov) == null) return reader_fail(rt, BK_ERR_TYPE, "value is not an object");
    if (!embed::slot_get(rt, val_id, &vv)) return reader_fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    HObject* obj = (HObject*)ov.get_heapptr();
    HString* k = rt.heap.int_to_hstring((long)idx);
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    bool res;
    if (!builtins::js_set_with_receiver((void*)rt.vm, rt.heap, obj, k, vv, ov, &res)) {
        return capi_vm_fault(rt);
    }
    if (!res) {
        embed::set_err(rt, BK_ERR_THROW, "Cannot assign to read only property");
        return BK_ERR_THROW;
    }
    return BK_OK;
}

fn int bk_has_prop(void* rtp, ulong obj_id, char* key, usz key_len, int* out) @export("bk_has_prop") {
    if (rtp == null || key == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal ov;
    if (capi_object(rt, obj_id, &ov) == null) return reader_fail(rt, BK_ERR_TYPE, "value is not an object");
    HObject* obj = (HObject*)ov.get_heapptr();
    HString* k = rt.heap.str_intern(key[:key_len]);
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    bool b;
    if (!builtins::js_has_property((void*)rt.vm, rt.heap, obj, k, &b)) {
        return capi_vm_fault(rt);
    }
    *out = b ? 1 : 0;
    return BK_OK;
}

fn int bk_delete_prop(void* rtp, ulong obj_id, char* key, usz key_len, int* out) @export("bk_delete_prop") {
    if (rtp == null || key == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal ov;
    if (capi_object(rt, obj_id, &ov) == null) return reader_fail(rt, BK_ERR_TYPE, "value is not an object");
    HObject* obj = (HObject*)ov.get_heapptr();
    HString* k = rt.heap.str_intern(key[:key_len]);
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    // Absent (own) property: report 0 and succeed, mirroring the header.
    if (obj.find_prop_idx((void*)k, rt.heap) < 0) { *out = 0; return BK_OK; }
    bool res;
    if (obj.flags.exotic_proxyobj) {
        if (!builtins::proxy_mop_delete((void*)rt.vm, rt.heap, obj, k, &res)) {
            return capi_vm_fault(rt);
        }
    } else if (obj.flags.exotic_module_ns) {
        res = false;
    } else {
        res = obj.es_delete_prop((void*)k, rt.heap);
    }
    if (!res) {
        // Strict-only engine: deleting a non-configurable property throws.
        embed::set_err(rt, BK_ERR_THROW, "Cannot delete property");
        return BK_ERR_THROW;
    }
    *out = 1;
    return BK_OK;
}

/// Fresh array of an object's own string property names (enumerable and not;
/// symbol keys skipped). The host walks it with bk_get_prop_index.
fn int bk_own_prop_names(void* rtp, ulong obj_id, ulong* out) @export("bk_own_prop_names") {
    if (rtp == null || out == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    TVal ov;
    if (capi_object(rt, obj_id, &ov) == null) return reader_fail(rt, BK_ERR_TYPE, "value is not an object");
    HObject* obj = (HObject*)ov.get_heapptr();
    Heap* h = rt.heap;

    HObject*? araw = h.alloc_object(hobject::ObjClass.ARRAY);
    if (catch araw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    HObject* arr = araw;
    arr.prototype = h.array_proto;
    uint idx = 0;

    // Proxy exotic: [[OwnPropertyKeys]] filtered to string keys.
    if (obj.flags.exotic_proxyobj) {
        HString** pkeys;
        uint pn;
        if (!builtins::proxy_filtered_own_keys((void*)rt.vm, h, obj, 1, &pkeys, &pn)) {
            return capi_vm_fault(rt);
        }
        defer h.free_func(h.heap_udata, pkeys);
        for (uint i = 0; i < pn; i++) {
            TVal kv; kv.set_string(pkeys[i]);
            builtins::array_set_elem(arr, i, kv, h);
        }
        idx = pn;
        TVal plen; plen.set_fastint((long)pn);
        arr.put_prop(h.str(heap::BuiltinStr.LENGTH), plen, hobject::PROP_FLAGS_WC, h);
        TVal v; v.set_object(arr);
        return capi_store(rt, v, out);
    }

    uint max_keys = builtins::own_key_buf_capacity(obj) + 64;
    usz bytes = (usz)(max_keys * HString*::size);
    HString** key_buf = (HString**)h.alloc_func(h.heap_udata, bytes);
    if (key_buf == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return BK_ERR_NOMEM; }
    defer h.free_func(h.heap_udata, key_buf);
    uint key_count = 0;

    // Integer-indexed own properties, ascending (ES9.1.11.1 OrdinaryOwnKeys).
    // Dense array / string-exotic / typed-array indices plus named integer keys.
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) for (uint i = 0; i < prim.char_length() && key_count < max_keys; i++) {
            key_buf[key_count++] = h.int_to_hstring((long)i);
        }
    }
    if (builtins::is_typed_array_class(obj.get_class())) {
        uint n = builtins::ta_element_count(obj);
        for (uint i = 0; i < n && key_count < max_keys; i++) {
            key_buf[key_count++] = h.int_to_hstring((long)i);
        }
    }
    // Named integer-indexed properties, mergesort-lite ascending.
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i, h) != null) {
            HString* key = (HString*)obj.prop_key_at(i, h);
            if (key.is_arridx() && !key.is_symbol() && key_count < max_keys) {
                key_buf[key_count++] = key;
            }
        }
    }
    bool array_part_is_indexed = obj.flags.exotic_array || obj.flags.exotic_arguments;
    if (obj.array_size > 0 && array_part_is_indexed) {
        for (uint i = 0; i < obj.array_size && key_count < max_keys; i++) {
            if (obj.array_part()[i].is_undefined()) continue;
            HString* ki = h.int_to_hstring((long)i);
            if (ki == null) continue;
            if (ki.is_arridx() && obj.find_prop_idx(ki, h) >= 0) continue;
            key_buf[key_count++] = ki;
        }
    }
    // Non-index string keys in insertion order (symbols skipped).
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i, h) != null) {
            HString* key = (HString*)obj.prop_key_at(i, h);
            if (key.is_arridx() || key.is_symbol()) continue;
            if (key_count < max_keys) key_buf[key_count++] = key;
        }
    }

    for (uint i = 0; i < key_count; i++) {
        TVal kv; kv.set_string(key_buf[i]);
        builtins::array_set_elem(arr, i, kv, h);
    }
    TVal len_tv; len_tv.set_fastint((long)key_count);
    arr.put_prop(h.str(heap::BuiltinStr.LENGTH), len_tv, hobject::PROP_FLAGS_WC, h);
    TVal v; v.set_object(arr);
    return capi_store(rt, v, out);
}

/// Call a JS function from outside a callback. argv/argc (NULL/0 for none),
/// this_val (0 for undefined). On BK_OK *out_val receives a caller-owned
/// handle. A thrown callee returns BK_ERR_THROW (or BK_ERR_INTERRUPT for an
/// interrupt); the exception is recorded on the runtime, not unwound through C.
fn int bk_call_rt(void* rtp, ulong func_id, ulong* argv, uint argc, ulong this_id,
                   ulong* out_val) @export("bk_call_rt") {
    if (rtp == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    embed::clear_err(rt);
    if (out_val != null) *out_val = 0;

    TVal fv;
    if (!embed::slot_get(rt, func_id, &fv)) return reader_fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!fv.is_lightfunc()) {
        if (!fv.is_object()) return reader_fail(rt, BK_ERR_TYPE, "value is not a function");
        HObject* fo = (HObject*)fv.get_heapptr();
        if (fo == null || !fo.flags.callable) return reader_fail(rt, BK_ERR_TYPE, "value is not a function");
    }
    if (argc > 0 && argv == null) return BK_ERR_INVALID;
    TVal tv;
    if (this_id == 0) { tv.set_undefined(); } else if (!embed::slot_get(rt, this_id, &tv)) { tv.set_undefined(); }

    TVal[16] args;
    uint n = argc > 16 ? 16 : argc;
    for (uint i = 0; i < n; i++) {
        TVal a;
        if (argv == null || !embed::slot_get(rt, argv[i], &a)) a.set_undefined();
        args[i] = a;
    }

    rt.heap.has_error = false;
    TVal res = rt.heap.call_fn((void*)rt.vm, fv, &args[0], n, tv);
    if (rt.heap.has_error) {
        return capi_vm_fault(rt);
    }
    if (out_val != null) return capi_store(rt, res, out_val);
    return BK_OK;
}
