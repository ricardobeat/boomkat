module boomkat::capi;

import boomkat::builtins;
import boomkat::embed;
import boomkat::vm;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import libc;

// ============================================================================
// The bk_ C ABI.
//
// This file is the C-facing face of `boomkat::embed`: it unwraps the opaque
// `bk_ctx`, marshals to integer handles and status codes, and owns nothing.
// The registry, the error formatter, the UTF-8 sink and the host trampoline
// all live in `src/embed.c3`, shared with the native C3 binding.
//
// Two conventions run through every entry point below:
//
//   * A `bk_ctx` is an `embed::Ctx*`, which names a runtime and, inside a host
//     callback, the call in progress. There is no second tier: the same reader
//     works in both places.
//   * A call that produces a value returns the handle, with 0 meaning failure;
//     a call that produces none returns a status. Either way the detail is on
//     the runtime, for bk_error / bk_error_code to report.
// ============================================================================

alias Runtime = embed::Runtime;
alias Ctx     = embed::Ctx;

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
const int BK_TYPE_OTHER     = embed::BK_TYPE_OTHER;

// ============================================================================
// Context plumbing
// ============================================================================

// The runtime behind a context, or null if the context is null.
macro Runtime* rt_of(void* p) => p == null ? null : ((Ctx*)p).rt;

// The live call behind a context, or null outside a callback.
macro void* bctx_of(void* p) => p == null ? null : ((Ctx*)p).bctx;

// Record a failure and hand back its code, so a caller can `return fail(...)`.
// Every failing entry point goes through here or through embed::set_err, which
// is what lets a host log bk_error unconditionally on a bad status.
fn int fail(Runtime* rt, int code, String msg) {
    if (rt != null) embed::set_err(rt, code, msg);
    return code;
}

// Resolve a handle against this context: the registry for an owned handle, the
// live call's scope for an argument handle.
fn bool resolve(void* ctxp, ulong id, TVal* out) {
    return embed::resolve_handle(rt_of(ctxp), bctx_of(ctxp), id, out);
}

// Store a value in the registry and return its handle, or 0 with the failure
// recorded. Reports exhaustion for every value kind, undefined included:
// handle 0 reads back as undefined, so returning it for a failed registration
// would be a silent wrong answer rather than an error.
fn ulong store(Runtime* rt, TVal v) {
    ulong id = embed::slot_alloc(rt, v);
    if (id == 0) embed::set_err(rt, BK_ERR_FULL, "value registry full");
    return id;
}

// A handle argument that did not resolve. Records the reason and yields 0, so
// the value-returning entry points can `return bad_handle(rt)`.
fn ulong bad_handle(Runtime* rt) {
    fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    return 0;
}

// ============================================================================
// Lifecycle
// ============================================================================

fn void* bk_open() @export("bk_open") {
    Runtime* rt = embed::create();
    if (rt == null) return null;
    // The host's bk_ctx is the runtime's own root context. A callback gets a
    // different one, built on the trampoline's stack, naming the same runtime.
    return (void*)&rt.root;
}

fn void bk_close(void* ctxp) @export("bk_close") {
    embed::destroy(rt_of(ctxp));
}

fn char* bk_version() @export("bk_version") {
    return "0.2.0";
}

// ============================================================================
// Eval
// ============================================================================

fn ulong bk_eval_named(void* ctxp, char* src, usz len, char* name, usz name_len)
        @export("bk_eval_named") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || src == null) return 0;
    TVal res;
    int rc = embed::eval_source(rt, src[:len],
                                name != null ? name[:name_len] : (char[])"<eval>", &res);
    if (rc != BK_OK) return 0;
    return store(rt, res);
}

fn ulong bk_eval(void* ctxp, char* src, usz len) @export("bk_eval") {
    return bk_eval_named(ctxp, src, len, "<eval>", 6);
}

fn int bk_drain(void* ctxp) @export("bk_drain") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    return embed::drain_microtasks(rt);
}

// ============================================================================
// Value lifetime
// ============================================================================

fn void bk_free(void* ctxp, ulong id) @export("bk_free") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return;
    embed::slot_release(rt, id);
}

fn ulong bk_persist(void* ctxp, ulong id) @export("bk_persist") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    return store(rt, v);
}

// ============================================================================
// Errors
// ============================================================================

fn char* bk_error(void* ctxp) @export("bk_error") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return "";
    return &rt.errmsg[0];
}

fn int bk_error_code(void* ctxp) @export("bk_error_code") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    return rt.errcode;
}

// Layout must match bk_error_info in include/boomkat.h on the target's ABI.
struct BkErrorInfo {
    int code;
    int line;
    int col;
    char* script_name;
}

fn int bk_error_info_of(void* ctxp, BkErrorInfo* out) @export("bk_error_info_of") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    out.code = rt.errcode;
    out.line = rt.err_line;
    out.col = rt.err_col;
    out.script_name = rt.err_name[0] != 0 ? &rt.err_name[0] : null;
    return BK_OK;
}

fn char* bk_status_str(int status) @export("bk_status_str") {
    return embed::status_name(status);
}

fn char* bk_type_str(int type) @export("bk_type_str") {
    return embed::type_name(type);
}

// ============================================================================
// Reading values
// ============================================================================

fn int bk_type_of(void* ctxp, ulong id) @export("bk_type_of") {
    if (rt_of(ctxp) == null) return BK_TYPE_OTHER;
    TVal v;
    if (!resolve(ctxp, id, &v)) return BK_TYPE_UNDEFINED;
    return embed::classify(v);
}

fn int bk_read_number(void* ctxp, ulong id, double* out) @export("bk_read_number") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_numeric()) return fail(rt, BK_ERR_TYPE, "value is not a number");
    *out = v.get_number_or_fastint();
    return BK_OK;
}

fn int bk_read_bool(void* ctxp, ulong id, int* out) @export("bk_read_bool") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_boolean()) return fail(rt, BK_ERR_TYPE, "value is not a boolean");
    *out = v.get_boolean() ? 1 : 0;
    return BK_OK;
}

fn int bk_read_string(void* ctxp, ulong id, char* buf, usz cap, usz* out_len)
        @export("bk_read_string") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_string()) return fail(rt, BK_ERR_TYPE, "value is not a string");
    HString* hs = (HString*)v.get_heapptr();
    // Symbols share the string tag but carry no meaningful text; copying their
    // bytes out would yield invalid UTF-8. JS forbids implicit conversion too.
    if (hs != null && hs.is_symbol()) return fail(rt, BK_ERR_TYPE, "value is a symbol");

    usz need = embed::utf8_write(hs, buf, buf == null ? 0 : cap);
    if (out_len != null) *out_len = need;
    if (buf == null) return BK_OK;
    if (need + 1 > cap) return fail(rt, BK_ERR_FULL, "buffer too small for string");
    buf[need] = 0;
    return BK_OK;
}

// ============================================================================
// Coercion tier
// ============================================================================

fn double bk_to_number(void* ctxp, ulong id) @export("bk_to_number") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return (double)(0.0 / 0.0);
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) {
        fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
        return (double)(0.0 / 0.0);
    }
    if (v.is_numeric()) return v.get_number_or_fastint();

    // Anything else may run user code (valueOf/toString) and therefore throw.
    // vm_to_number reports through the heap's error channel rather than an
    // optional, so the throw is picked up here and turned into a status.
    rt.heap.has_error = false;
    double d = vm::vm_to_number(rt.vm, &v);
    if (rt.heap.has_error) {
        vm_fault(rt);
        return (double)(0.0 / 0.0);
    }
    return d;
}

fn int bk_to_bool(void* ctxp, ulong id) @export("bk_to_bool") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, id, &v)) {
        fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
        return 0;
    }
    // ToBoolean never calls user code, so this cannot throw.
    return builtins::builtin_to_boolean(&v) ? 1 : 0;
}

fn ulong bk_to_string(void* ctxp, ulong id) @export("bk_to_string") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    HString* s;
    if (embed::to_string(rt, v, &s) != BK_OK) return 0;
    TVal sv; sv.set_string(s);
    return store(rt, sv);
}

// Convert to text into a context-owned ring buffer. This is the short path
// behind `printf("%s", bk_cstr(...))`: no size query, no buffer, no free.
fn char* bk_cstr(void* ctxp, ulong id, usz* out_len) @export("bk_cstr") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return null;
    TVal v;
    if (!resolve(ctxp, id, &v)) {
        fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
        return null;
    }
    HString* s;
    if (embed::to_string(rt, v, &s) != BK_OK) return null;

    usz need = embed::utf8_len(s);
    char* buf = embed::cstr_slot(rt, need);
    if (buf == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    embed::utf8_write(s, buf, need + 1);
    buf[need] = 0;
    if (out_len != null) *out_len = need;
    return buf;
}

fn char* bk_strdup(void* ctxp, ulong id, usz* out_len) @export("bk_strdup") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return null;
    TVal v;
    if (!resolve(ctxp, id, &v)) {
        fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
        return null;
    }
    HString* s;
    if (embed::to_string(rt, v, &s) != BK_OK) return null;

    usz need = embed::utf8_len(s);
    // libc malloc, not the engine allocator: the header documents free().
    char* buf = (char*)libc::malloc(need + 1);
    if (buf == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    embed::utf8_write(s, buf, need + 1);
    buf[need] = 0;
    if (out_len != null) *out_len = need;
    return buf;
}

// ============================================================================
// Building values
// ============================================================================

fn ulong bk_number(void* ctxp, double d) @export("bk_number") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_number(d);
    return store(rt, v);
}

fn ulong bk_bool(void* ctxp, int b) @export("bk_bool") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_boolean(b != 0);
    return store(rt, v);
}

fn ulong bk_null(void* ctxp) @export("bk_null") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_null();
    return store(rt, v);
}

fn ulong bk_undefined(void* ctxp) @export("bk_undefined") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_undefined();
    return store(rt, v);
}

fn ulong bk_string(void* ctxp, char* utf8, usz len) @export("bk_string") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || utf8 == null) return 0;
    embed::clear_err(rt);
    HString* s = rt.heap.str_intern(utf8[:len]);
    if (s == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    TVal v; v.set_string(s);
    return store(rt, v);
}

fn ulong bk_object(void* ctxp) @export("bk_object") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HObject*? oraw = rt.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch oraw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    HObject* o = oraw;
    o.prototype = rt.heap.object_proto;
    TVal v; v.set_object(o);
    return store(rt, v);
}

// Fresh empty array. Shared by bk_array, bk_array_of and bk_keys.
fn HObject* new_array(Runtime* rt) {
    HObject*? araw = rt.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch araw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    HObject* a = araw;
    a.prototype = rt.heap.array_proto;
    return a;
}

fn ulong bk_array(void* ctxp) @export("bk_array") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HObject* a = new_array(rt);
    if (a == null) return 0;
    TVal v; v.set_object(a);
    return store(rt, v);
}

fn ulong bk_array_of(void* ctxp, ulong* elems, uint n) @export("bk_array_of") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (n > 0 && elems == null) { embed::set_err(rt, BK_ERR_INVALID, "null element array"); return 0; }
    HObject* a = new_array(rt);
    if (a == null) return 0;
    for (uint i = 0; i < n; i++) {
        TVal ev;
        if (!resolve(ctxp, elems[i], &ev)) ev.set_undefined();
        builtins::array_set_elem(a, i, ev, rt.heap);
    }
    TVal len_tv; len_tv.set_fastint((long)n);
    a.put_prop(rt.heap.str(heap::BuiltinStr.LENGTH), len_tv, hobject::PROP_FLAGS_WEC, rt.heap);
    TVal v; v.set_object(a);
    return store(rt, v);
}

fn ulong bk_global(void* ctxp) @export("bk_global") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal g;
    if (rt.vm.global_env != null && rt.vm.global_env.bindings != null) {
        g.set_object(rt.vm.global_env.bindings);
    } else {
        g.set_undefined();
    }
    return store(rt, g);
}

// ============================================================================
// Properties
// ============================================================================

// Resolve a handle that must name an object, recording the failure otherwise.
fn HObject* as_object(void* ctxp, ulong id, TVal* out) {
    Runtime* rt = rt_of(ctxp);
    if (!resolve(ctxp, id, out)) {
        fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
        return null;
    }
    if (!out.is_object()) {
        fail(rt, BK_ERR_TYPE, "value is not an object");
        return null;
    }
    return (HObject*)out.get_heapptr();
}

// Surface a VM failure (heap error channel) as a status, distinguishing an
// interrupt from an ordinary throw.
fn int vm_fault(Runtime* rt) {
    if (rt.heap.uncatchable_throw) {
        rt.heap.uncatchable_throw = false;
        embed::set_err(rt, BK_ERR_INTERRUPT, "interrupted");
        return BK_ERR_INTERRUPT;
    }
    embed::describe_error(rt, &rt.heap.error_value);
    return BK_ERR_THROW;
}

// Shared by the named and indexed getters.
fn ulong get_key(void* ctxp, ulong obj_id, HString* k) {
    Runtime* rt = rt_of(ctxp);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return 0;
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    TVal got;
    if (!builtins::js_get_with_receiver((void*)rt.vm, rt.heap, obj, k, ov, &got)) {
        vm_fault(rt);
        return 0;
    }
    return store(rt, got);
}

fn ulong bk_get(void* ctxp, ulong obj_id, char* key, usz key_len) @export("bk_get") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null) return 0;
    embed::clear_err(rt);
    return get_key(ctxp, obj_id, rt.heap.str_intern(key[:key_len]));
}

fn ulong bk_get_index(void* ctxp, ulong obj_id, uint idx) @export("bk_get_index") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    return get_key(ctxp, obj_id, rt.heap.int_to_hstring((long)idx));
}

// Shared by the named and indexed setters.
fn int set_key(void* ctxp, ulong obj_id, HString* k, ulong val_id) {
    Runtime* rt = rt_of(ctxp);
    TVal ov, vv;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    if (!resolve(ctxp, val_id, &vv)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    bool res;
    if (!builtins::js_set_with_receiver((void*)rt.vm, rt.heap, obj, k, vv, ov, &res)) {
        return vm_fault(rt);
    }
    // Strict-only engine: a Set that returns false throws a TypeError.
    if (!res) return fail(rt, BK_ERR_THROW, "Cannot assign to read only property");
    return BK_OK;
}

fn int bk_set(void* ctxp, ulong obj_id, char* key, usz key_len, ulong val_id)
        @export("bk_set") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    return set_key(ctxp, obj_id, rt.heap.str_intern(key[:key_len]), val_id);
}

fn int bk_set_index(void* ctxp, ulong obj_id, uint idx, ulong val_id)
        @export("bk_set_index") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    return set_key(ctxp, obj_id, rt.heap.int_to_hstring((long)idx), val_id);
}

fn int bk_has(void* ctxp, ulong obj_id, char* key, usz key_len, int* out)
        @export("bk_has") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    HString* k = rt.heap.str_intern(key[:key_len]);
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    bool b;
    if (!builtins::js_has_property((void*)rt.vm, rt.heap, obj, k, &b)) return vm_fault(rt);
    *out = b ? 1 : 0;
    return BK_OK;
}

fn int bk_delete(void* ctxp, ulong obj_id, char* key, usz key_len, int* out)
        @export("bk_delete") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    HString* k = rt.heap.str_intern(key[:key_len]);
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    // Absent own property: report 0 and succeed, mirroring the header.
    if (obj.find_prop_idx((void*)k, rt.heap) < 0) { *out = 0; return BK_OK; }
    bool res;
    if (obj.flags.exotic_proxyobj) {
        if (!builtins::proxy_mop_delete((void*)rt.vm, rt.heap, obj, k, &res)) return vm_fault(rt);
    } else if (obj.flags.exotic_module_ns) {
        res = false;
    } else {
        res = obj.es_delete_prop((void*)k, rt.heap);
    }
    // Strict-only engine: deleting a non-configurable property throws.
    if (!res) return fail(rt, BK_ERR_THROW, "Cannot delete property");
    *out = 1;
    return BK_OK;
}

fn ulong bk_keys(void* ctxp, ulong obj_id) @export("bk_keys") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return 0;
    Heap* h = rt.heap;

    HObject* arr = new_array(rt);
    if (arr == null) return 0;

    // Proxy exotic: [[OwnPropertyKeys]] filtered to string keys.
    if (obj.flags.exotic_proxyobj) {
        HString** pkeys;
        uint pn;
        if (!builtins::proxy_filtered_own_keys((void*)rt.vm, h, obj, 1, &pkeys, &pn)) {
            vm_fault(rt);
            return 0;
        }
        defer h.free_func(h.heap_udata, pkeys);
        for (uint i = 0; i < pn; i++) {
            TVal kv; kv.set_string(pkeys[i]);
            builtins::array_set_elem(arr, i, kv, h);
        }
        TVal plen; plen.set_fastint((long)pn);
        arr.put_prop(h.str(heap::BuiltinStr.LENGTH), plen, hobject::PROP_FLAGS_WC, h);
        TVal v; v.set_object(arr);
        return store(rt, v);
    }

    uint max_keys = builtins::own_key_buf_capacity(obj) + 64;
    usz bytes = (usz)(max_keys * HString*::size);
    HString** key_buf = (HString**)h.alloc_func(h.heap_udata, bytes);
    if (key_buf == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
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
    // Named integer-indexed properties.
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
    return store(rt, v);
}

// ============================================================================
// Calls
// ============================================================================

// Argument counts up to this are staged on the stack; the engine's own call
// paths cap staged arguments the same way, and a host needing more can build
// an array in JS.
const uint MAX_CALL_ARGS = 16;

fn ulong bk_call(void* ctxp, ulong fn_id, ulong this_id, ulong* argv, uint argc)
        @export("bk_call") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);

    void* bctx = bctx_of(ctxp);

    TVal fv;
    if (!resolve(ctxp, fn_id, &fv)) return bad_handle(rt);
    // Outside a callback there is no JS frame to throw into, so a non-callable
    // callee is reported as a status. Inside one it must reach JS as a real
    // TypeError, which host_call stages, so the check is left to it: doing it
    // here would swallow the exception and hand the script an undefined.
    if (bctx == null && !fv.is_lightfunc()) {
        HObject* fo = fv.is_object() ? (HObject*)fv.get_heapptr() : null;
        if (fo == null || !fo.flags.callable) {
            fail(rt, BK_ERR_TYPE, "value is not a function");
            return 0;
        }
    }
    if (argc > 0 && argv == null) {
        fail(rt, BK_ERR_INVALID, "null argument array");
        return 0;
    }

    TVal tv;
    if (this_id == 0 || !resolve(ctxp, this_id, &tv)) tv.set_undefined();

    TVal[MAX_CALL_ARGS] args;
    uint n = argc > MAX_CALL_ARGS ? MAX_CALL_ARGS : argc;
    for (uint i = 0; i < n; i++) {
        TVal a;
        if (!resolve(ctxp, argv[i], &a)) a.set_undefined();
        args[i] = a;
    }

    TVal res;
    if (bctx != null) {
        // Inside a callback the call goes through the host entry point, which
        // stages the throw on this call rather than unwinding through C.
        bool ok = false;
        res = builtins::host_call((builtins::BuiltinContext*)bctx, fv, &args[0], n, tv, &ok);
        if (!ok) {
            // An interrupt heard here stays flagged: the staged re-throw that
            // fires when this callback returns must remain uncatchable, so the
            // flag clears only at the outermost boundary that surfaces it.
            if (rt.heap.uncatchable_throw) {
                embed::set_err(rt, BK_ERR_INTERRUPT, "interrupted");
            } else {
                embed::describe_error(rt, &rt.heap.error_value);
            }
            return 0;
        }
    } else {
        rt.heap.has_error = false;
        res = rt.heap.call_fn((void*)rt.vm, fv, &args[0], n, tv);
        if (rt.heap.has_error) {
            vm_fault(rt);
            return 0;
        }
    }
    return store(rt, res);
}

// ============================================================================
// Host functions
// ============================================================================

// Layout must match bk_fn_def in include/boomkat.h on the target's ABI.
struct BkFnDef {
    char* name;
    void* cfn;
    int   arity;
    uint  flags;
    void* udata;
}

const uint BK_CTOR = 1;

// Install a table of host functions, ending at the first entry with a null
// name. `target_id` 0 means globalThis, which is an environment binding rather
// than a property write, so the two cases stay separate below.
fn int bk_register(void* ctxp, ulong target_id, BkFnDef* defs) @export("bk_register") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || defs == null) return BK_ERR_INVALID;
    embed::clear_err(rt);

    TVal ov;
    HObject* target = null;
    if (target_id != 0) {
        target = as_object(ctxp, target_id, &ov);
        if (target == null) return rt.errcode;
    }

    for (usz i = 0; defs[i].name != null; i++) {
        BkFnDef* d = &defs[i];
        if (d.cfn == null) return fail(rt, BK_ERR_INVALID, "table entry has no function");
        usz nlen = 0;
        while (d.name[nlen] != 0) nlen++;

        // The registration record outlives the call, so it is heap-allocated
        // and owned by the runtime; the host function table keeps the only
        // pointer.
        void* raw = rt.heap.alloc_func(rt.heap.heap_udata, embed::HostReg::size);
        if (raw == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
        embed::HostReg* reg = (embed::HostReg*)raw;
        reg.cfn = d.cfn;
        reg.udata = d.udata;

        TVal fv;
        int rc = embed::make_fn_value(rt, d.name[:nlen], (void*)&embed::host_trampoline,
                                      raw, d.arity, (d.flags & BK_CTOR) != 0, &fv);
        if (rc != BK_OK) {
            rt.heap.free_func(rt.heap.heap_udata, raw);
            return rc;
        }

        if (target == null) {
            rc = embed::declare_global(rt, d.name[:nlen], fv);
            if (rc != BK_OK) return rc;
        } else {
            HString* k = rt.heap.str_intern(d.name[:nlen]);
            if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
            if (!target.put_prop(k, fv, hobject::PROP_FLAGS_WC, rt.heap)) {
                return fail(rt, BK_ERR_INTERNAL, "could not install function on target");
            }
        }
    }
    return BK_OK;
}

fn int bk_set_global(void* ctxp, char* name, usz name_len, ulong val_id)
        @export("bk_set_global") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || name == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, val_id, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    return embed::declare_global(rt, name[:name_len], v);
}

// --- inside a callback ------------------------------------------------------
//
// These need the call, not just the runtime, so they report "nothing" when the
// context is the runtime's root rather than a live call: 0 arguments, handle 0,
// no return value set.

fn uint bk_argc(void* ctxp) @export("bk_argc") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return 0;
    return builtins::host_argc((builtins::BuiltinContext*)bctx);
}

// Handle to argument `i`. Out-of-range yields a handle to undefined, matching
// JS semantics and sparing every host an arity check.
fn ulong bk_arg(void* ctxp, uint i) @export("bk_arg") {
    if (bctx_of(ctxp) == null) return 0;
    return embed::scope_handle(rt_of(ctxp), (ulong)(heap::HOST_SCOPE_ARG0 + i));
}

fn ulong bk_this(void* ctxp) @export("bk_this") {
    if (bctx_of(ctxp) == null) return 0;
    return embed::scope_handle(rt_of(ctxp), (ulong)heap::HOST_SCOPE_THIS);
}

fn ulong bk_new_target(void* ctxp) @export("bk_new_target") {
    if (bctx_of(ctxp) == null) return 0;
    return embed::scope_handle(rt_of(ctxp), (ulong)heap::HOST_SCOPE_NEW_TARGET);
}

fn int bk_is_construct(void* ctxp) @export("bk_is_construct") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return 0;
    return builtins::host_is_construct((builtins::BuiltinContext*)bctx) ? 1 : 0;
}

fn void bk_return(void* ctxp, ulong id) @export("bk_return") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return;
    TVal v;
    if (!resolve(ctxp, id, &v)) return;
    builtins::host_return((builtins::BuiltinContext*)bctx, v);
}

// Throw a fresh Error of `kind` with `msg`. Does not unwind: the callback must
// still return normally, and the throw beats any return value set.
fn void bk_throw_error(void* ctxp, int kind, char* msg) @export("bk_throw_error") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null || msg == null) return;
    usz n = 0;
    while (msg[n] != 0) n++;
    builtins::host_throw_error((builtins::BuiltinContext*)bctx, kind, msg[:n]);
}

fn void bk_throw(void* ctxp, ulong id) @export("bk_throw") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return;
    TVal v;
    if (!resolve(ctxp, id, &v)) return;
    builtins::host_throw((builtins::BuiltinContext*)bctx, v);
}

// ============================================================================
// Interrupt
// ============================================================================

// Install, replace, or clear the interrupt handler. The callback runs on the
// engine thread at VM safepoints; it must not call back into the engine. A
// host interrupting from another thread sets a flag in `opaque` and returns it
// here.
fn void bk_set_interrupt(void* ctxp, void* cb, void* opaque) @export("bk_set_interrupt") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return;
    rt.heap.capi_interrupt_fn = cb;
    rt.heap.capi_interrupt_opaque = opaque;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
}
