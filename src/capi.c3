module boomkat::capi @feat(!BYTECODE_ONLY);

import boomkat::agent;
import boomkat::builtins;
import boomkat::embed;
import boomkat::esm;
import boomkat::vm;
import boomkat::heap;
import boomkat::lexer;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import libc;

// C ABI marshalling over the shared embedding core. Context selection owns
// per-realm error state; the runtime owns registry roots and callback payloads.

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
fn Runtime* rt_of(void* p) @inline {
    if (p == null) return null;
    Ctx* ctx = (Ctx*)p;
    embed::select_context(ctx);
    return ctx.rt;
}

// The live call behind a context, or null outside a callback.
macro void* bctx_of(void* p) => p == null ? null : ((Ctx*)p).bctx;

// Record a failure and hand back its code, so a caller can `return fail(...)`.
// Every failing entry point goes through here or through embed::set_err, which
// is what lets a host log bk_get_error_message unconditionally on a bad status.
fn int fail(Runtime* rt, int code, String msg) {
    if (rt != null) embed::set_err(rt, code, msg);
    return code;
}

// Resolve a handle against this context: the registry for an owned handle, the
// live call's scope for an argument handle.
fn bool resolve(void* ctxp, ulong id, TVal* out) {
    return embed::resolve_handle(rt_of(ctxp), id, out);
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

fn void* bk_new_runtime() @export("bk_new_runtime") => embed::create();

// A context that owns its runtime; bk_destroy releases both.
fn void* bk_create() @export("bk_create") {
    Runtime* rt = embed::create();
    if (rt == null) return null;
    Ctx* ctx = embed::new_context(rt);
    if (ctx == null) { embed::destroy(rt); return null; }
    rt.owned_by_context = true;
    return ctx;
}

fn void bk_destroy(void* ctxp) @export("bk_destroy") {
    if (ctxp == null) return;
    Ctx* ctx = (Ctx*)ctxp;
    if (ctx.bctx != null) return;
    if (ctx.rt.owned_by_context) { embed::destroy(ctx.rt); return; }
    embed::free_context(ctx);
}

fn void* bk_new_context(void* rtp) @export("bk_new_context") {
    if (rtp == null) return null;
    return embed::new_context((Runtime*)rtp);
}

fn void bk_free_runtime(void* rtp) @export("bk_free_runtime") => embed::destroy((Runtime*)rtp);

fn void bk_free_context(void* ctxp) @export("bk_free_context") => embed::free_context((Ctx*)ctxp);

fn void* bk_get_runtime(void* ctxp) @export("bk_get_runtime") => ctxp == null ? null : ((Ctx*)ctxp).rt;

fn void bk_set_runtime_opaque(void* rtp, void* opaque) @export("bk_set_runtime_opaque") {
    if (rtp != null) ((Runtime*)rtp).opaque = opaque;
}

fn void* bk_get_runtime_opaque(void* rtp) @export("bk_get_runtime_opaque") => rtp == null ? null : ((Runtime*)rtp).opaque;

fn void bk_set_context_opaque(void* ctxp, void* opaque) @export("bk_set_context_opaque") {
    Runtime* rt = rt_of(ctxp);
    if (rt != null) rt.context_opaque = opaque;
}

fn void* bk_get_context_opaque(void* ctxp) @export("bk_get_context_opaque") {
    Runtime* rt = rt_of(ctxp);
    return rt == null ? null : rt.context_opaque;
}



fn char* bk_version() @export("bk_version") {
    return "0.2.0";
}

// ============================================================================
// Eval
// ============================================================================

fn ulong bk_eval_ex(void* ctxp, char* src, usz len, char* filename, uint flags) @export("bk_eval_ex") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (src == null || (flags & ~3u) != 0) { fail(rt, BK_ERR_INVALID, "invalid source or eval flags"); return 0; }
    char[] name = filename != null ? ((ZString)filename).str_view() : (char[])"<eval>";
    TVal result;
    bool owned;
    int rc;
    if ((flags & 1u) != 0) {
        rc = embed::eval_module(rt, src[:len], name, &result);
    } else {
        rc = embed::eval_source(rt, src[:len], name, &result, &owned, strict: (flags & 2u) != 0);
    }
    if (rc != BK_OK) return 0;
    ulong id = store(rt, result);
    if (owned) rt.heap.decref_tval(&result);
    return id;
}





// Copy the C string `s` (or nothing when NULL) to `*at` in the runtime's JSX buffer.
fn char[] jsx_copy(char* s, char** at) {
    if (s == null) return {};
    sz n = ((ZString)s).len();
    char[] out = (*at)[:(usz)n];
    mem::copy(*at, s, n);
    *at += n;
    return out;
}

fn int bk_set_jsx(void* ctxp, int enable, int runtime, char* import_source, char* factory, char* fragment)
        @export("bk_set_jsx") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || runtime < 0 || runtime > 2) return BK_ERR_INVALID;
    usz total = 1;
    char*[3] strings = { import_source, factory, fragment };
    foreach (s : strings) {
        if (s != null) total += (usz)((ZString)s).len();
    }
    Heap* h = rt.heap;
    char* buf = (char*)h.alloc_func(h.heap_udata, total);
    if (buf == null) return BK_ERR_NOMEM;
    char* at = buf;
    lexer::JsxOptions o;
    o.enabled = enable != 0;
    o.runtime = (lexer::JsxRuntime)runtime;
    o.import_source = jsx_copy(import_source, &at);
    o.factory = jsx_copy(factory, &at);
    o.fragment = jsx_copy(fragment, &at);
    o.imply_runtime();
    if (rt.jsx_buf != null) h.free_func(h.heap_udata, (void*)rt.jsx_buf);
    rt.jsx_buf = buf;
    h.jsx = o;
    return BK_OK;
}



fn int bk_define_module(void* ctxp, char* name, usz name_len, char* src, usz len)
        @export("bk_define_module") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    if (name == null || name_len == 0 || src == null) {
        return fail(rt, BK_ERR_INVALID, "bk_define_module: missing name or source");
    }
    if (!esm::define_module(rt.heap, name[:name_len], src[:len])) {
        return fail(rt, BK_ERR_NOMEM, "out of memory");
    }
    return BK_OK;
}

fn int bk_is_job_pending(void* rtp) @export("bk_is_job_pending") {
    if (rtp == null) return 0;
    Heap* h = ((Runtime*)rtp).heap;
    return h.microtask_head < h.microtask_count ? 1 : 0;
}

fn int bk_execute_pending_job(void* rtp, void** context) @export("bk_execute_pending_job") {
    if (context != null) *context = null;
    if (rtp == null) return BK_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    Heap* h = rt.heap;
    if (h.microtask_draining || h.microtask_head >= h.microtask_count) return 0;
    TVal handler = h.microtask_queue[h.microtask_head * 3];
    Ctx* ctx = embed::realm_context(rt, heap::function_realm(h, handler) ?? h.realm);
    if (ctx == null) ctx = rt.active;
    embed::select_context(ctx);
    if (context != null) *context = ctx;
    embed::clear_err(rt);
    h.uncatchable_throw = false;
    h.has_error = false;
    h.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
    h.drain_microtasks(rt.vm, report: false, max_jobs: 1, force: true);
    if (h.uncatchable_throw) return vm_fault(rt);
    return 1;
}

fn int bk_run_jobs(void* rtp) @export("bk_run_jobs") {
    if (rtp == null) return BK_ERR_INVALID;
    return embed::drain_microtasks((Runtime*)rtp);
}

// ============================================================================
// Value lifetime
// ============================================================================

fn void bk_free_value(void* ctxp, ulong id) @export("bk_free_value") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return;
    embed::slot_release(rt, id);
}

fn ulong bk_dup_value(void* ctxp, ulong id) @export("bk_dup_value") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal v;
    if (!resolve(ctxp, id, &v)) return bad_handle(rt);
    return store(rt, v);
}

// ============================================================================
// Errors
// ============================================================================

fn char* bk_get_error_message(void* ctxp) @export("bk_get_error_message") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return "";
    return &rt.errmsg[0];
}

fn int bk_get_error_code(void* ctxp) @export("bk_get_error_code") {
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

fn int bk_get_error_info(void* ctxp, BkErrorInfo* out) @export("bk_get_error_info") {
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

fn int bk_get_type(void* ctxp, ulong id) @export("bk_get_type") {
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
    if (rt.heap.has_error || rt.heap.uncatchable_throw) {
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
    TVal sv; sv.set_string_borrowed(s);
    return store(rt, sv);
}

fn char* bk_to_cstring(void* ctxp, ulong id, usz* out_len) @export("bk_to_cstring") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return null;
    TVal value;
    if (!resolve(ctxp, id, &value)) { bad_handle(rt); return null; }
    HString* string;
    if (embed::to_string(rt, value, &string) != BK_OK) return null;
    usz length = embed::utf8_len(string);
    char* buffer = (char*)rt.heap.alloc_func(rt.heap.heap_udata, length + 1);
    if (buffer == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    embed::utf8_write(string, buffer, length + 1);
    buffer[length] = 0;
    if (out_len != null) *out_len = length;
    return buffer;
}

fn char* bk_cstr(void* ctxp, ulong id, usz* out_len) @export("bk_cstr") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return null;
    TVal value;
    if (!resolve(ctxp, id, &value)) { bad_handle(rt); return null; }
    HString* string;
    if (embed::to_string(rt, value, &string) != BK_OK) return null;
    usz length = embed::utf8_len(string);
    char* buffer = embed::cstr_slot(rt, length);
    if (buffer == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    embed::utf8_write(string, buffer, length + 1);
    buffer[length] = 0;
    if (out_len != null) *out_len = length;
    return buffer;
}

fn void bk_free_cstring(void* ctxp, char* string) @export("bk_free_cstring") {
    if (ctxp == null || string == null) return;
    Heap* h = ((Ctx*)ctxp).rt.heap;
    h.free_func(h.heap_udata, string);
}

fn ulong bk_get_exception(void* ctxp) @export("bk_get_exception") {
    Runtime* rt = rt_of(ctxp);
    return rt == null ? 0 : embed::take_exception(rt);
}

// ============================================================================
// Building values
// ============================================================================

fn ulong bk_new_number(void* ctxp, double d) @export("bk_new_number") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_number(d);
    return store(rt, v);
}

fn ulong bk_new_bool(void* ctxp, int b) @export("bk_new_bool") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_boolean(b != 0);
    return store(rt, v);
}

fn ulong bk_new_null(void* ctxp) @export("bk_new_null") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_null();
    return store(rt, v);
}

fn ulong bk_new_undefined(void* ctxp) @export("bk_new_undefined") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    TVal v; v.set_undefined();
    return store(rt, v);
}

fn ulong bk_new_string(void* ctxp, char* utf8, usz len) @export("bk_new_string") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || utf8 == null) return 0;
    embed::clear_err(rt);
    HString* s = rt.heap.str_intern(utf8[:len]);
    if (s == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    TVal v; v.set_string_borrowed(s);
    return store(rt, v);
}

fn ulong bk_new_object(void* ctxp) @export("bk_new_object") {
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

// Fresh empty array. Shared by bk_new_array, bk_new_array_from and bk_get_own_property_names.
fn HObject* new_array(Runtime* rt) {
    HObject*? araw = rt.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch araw) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return null; }
    HObject* a = araw;
    a.prototype = rt.heap.array_proto;
    return a;
}

fn ulong bk_new_array(void* ctxp) @export("bk_new_array") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    HObject* a = new_array(rt);
    if (a == null) return 0;
    TVal v; v.set_object(a);
    return store(rt, v);
}

fn ulong bk_new_array_from(void* ctxp, ulong* elems, uint n) @export("bk_new_array_from") {
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

fn ulong bk_get_global_object(void* ctxp) @export("bk_get_global_object") {
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
        embed::finish_interrupt(rt);
        embed::set_err(rt, BK_ERR_INTERRUPT, "interrupted");
        return BK_ERR_INTERRUPT;
    }
    embed::describe_error(rt, &rt.heap.error_value);
    return BK_ERR_THROW;
}

// Shared by the named and indexed getters. A primitive base reads through its
// wrapper with the primitive as receiver (GetV, ECMA-262 §7.3.3).
fn ulong get_key(void* ctxp, ulong obj_id, HString* k) {
    Runtime* rt = rt_of(ctxp);
    TVal ov;
    if (!resolve(ctxp, obj_id, &ov)) return bad_handle(rt);
    if (ov.is_undefined() || ov.is_null()) {
        fail(rt, BK_ERR_TYPE, "cannot read properties of null or undefined");
        return 0;
    }
    if (k == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    HObject* obj = builtins::to_object_for_lookup(rt.heap, ov);
    if (obj == null) { embed::set_err(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    // A fresh wrapper is unreachable from JS; hold it while getters run.
    ulong wrapper = 0;
    if (!ov.is_object()) {
        TVal wv;
        wv.set_object(obj);
        wrapper = store(rt, wv);
        if (wrapper == 0) return 0;
    }
    defer if (wrapper != 0) embed::slot_release(rt, wrapper);
    TVal got;
    if (!builtins::js_get_with_receiver((void*)rt.vm, rt.heap, obj, k, ov, &got)) {
        vm_fault(rt);
        return 0;
    }
    return store(rt, got);
}

fn ulong bk_get_property(void* ctxp, ulong obj_id, char* key, usz key_len) @export("bk_get_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null) return 0;
    embed::clear_err(rt);
    return get_key(ctxp, obj_id, rt.heap.str_intern(key[:key_len]));
}

fn ulong bk_get_property_uint32(void* ctxp, ulong obj_id, uint idx) @export("bk_get_property_uint32") {
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

fn int bk_set_property(void* ctxp, ulong obj_id, char* key, usz key_len, ulong val_id)
        @export("bk_set_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    return set_key(ctxp, obj_id, rt.heap.str_intern(key[:key_len]), val_id);
}

fn int bk_set_property_uint32(void* ctxp, ulong obj_id, uint idx, ulong val_id)
        @export("bk_set_property_uint32") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    return set_key(ctxp, obj_id, rt.heap.int_to_hstring((long)idx), val_id);
}

fn int bk_has_property(void* ctxp, ulong obj_id, char* key, usz key_len, int* out)
        @export("bk_has_property") {
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

fn int bk_delete_property(void* ctxp, ulong obj_id, char* key, usz key_len, int* out)
        @export("bk_delete_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || key == null || out == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal ov;
    HObject* obj = as_object(ctxp, obj_id, &ov);
    if (obj == null) return rt.errcode;
    HString* k = rt.heap.str_intern(key[:key_len]);
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    // Absent own property: report 0 and succeed. A proxy reports its trap's
    // answer, since only the trap knows whether the key existed.
    // A module namespace is probed by key so a TDZ export does not throw.
    if (obj.flags.exotic_module_ns) {
        if (obj.find_prop_idx((void*)k, rt.heap) < 0) { *out = 0; return BK_OK; }
    } else if (!obj.is_proxy()) {
        builtins::ProxyDesc own;
        builtins::ordinary_own_desc(rt.heap, obj, k, &own);
        if (!own.found) { *out = 0; return BK_OK; }
    }
    bool res;
    if (!builtins::object_mop_delete((void*)rt.vm, rt.heap, obj, k, &res)) return vm_fault(rt);
    // Strict-only engine: deleting a non-configurable property throws.
    if (!res) return fail(rt, BK_ERR_THROW, "Cannot delete property");
    *out = 1;
    return BK_OK;
}

fn ulong bk_get_own_property_names(void* ctxp, ulong obj_id) @export("bk_get_own_property_names") {
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
    if (obj.is_proxy()) {
        HString** pkeys;
        uint pn;
        if (!builtins::proxy_filtered_own_keys((void*)rt.vm, h, obj, 1, &pkeys, &pn)) {
            vm_fault(rt);
            return 0;
        }
        defer h.free_func(h.heap_udata, pkeys);
        for (uint i = 0; i < pn; i++) {
            TVal kv; kv.set_string_borrowed(pkeys[i]);
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
        if (prim != null) for (uint i = 0; i < prim.unit_len() && key_count < max_keys; i++) {
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
            if (!obj.dense_idx_present(i)) continue;
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
        TVal kv; kv.set_string_borrowed(key_buf[i]);
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

fn ulong bk_call(void* ctxp, ulong fn_id, ulong this_id, ulong* argv, uint argc) @export("bk_call") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    embed::clear_err(rt);
    if (argc > 0xFFFFu) return bk_throw_error(ctxp, builtins::HOST_ERR_RANGE, "too many arguments");
    TVal function;
    if (!resolve(ctxp, fn_id, &function)) return bad_handle(rt);
    if (!builtins::is_callable_tval(function)) { fail(rt, BK_ERR_TYPE, "value is not a function"); return 0; }
    if (argc != 0 && argv == null) { fail(rt, BK_ERR_INVALID, "null argument array"); return 0; }
    TVal this_value;
    if (this_id == 0) { this_value.set_undefined(); }
    else if (!resolve(ctxp, this_id, &this_value)) { return bad_handle(rt); }
    TVal[16] local_args;
    TVal* args = &local_args;
    if (argc > local_args.len) {
        args = (TVal*)rt.heap.alloc_func(rt.heap.heap_udata, (usz)argc * TVal::size);
        if (args == null) { fail(rt, BK_ERR_NOMEM, "out of memory"); return 0; }
    }
    defer if (args != &local_args) rt.heap.free_func(rt.heap.heap_udata, args);
    for (uint i = 0; i < argc; i++) {
        if (!resolve(ctxp, argv[i], &args[i])) return bad_handle(rt);
    }
    rt.heap.has_error = false;
    TVal result = rt.heap.call_fn(rt.vm, function, args, argc, this_value);
    if (rt.heap.has_error || rt.heap.uncatchable_throw) {
        vm_fault(rt);
        rt.heap.has_error = false;
        rt.vm.has_error = false;
        rt.vm.throw_pending = false;
        return 0;
    }
    return store(rt, result);
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
fn int bk_set_function_list(void* ctxp, ulong target_id, BkFnDef* defs) @export("bk_set_function_list") {
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

        int rc = install_function(rt, target, d.name[:nlen], d.cfn, d.udata, d.arity, d.flags, false);
        if (rc != BK_OK) return rc;
    }
    return BK_OK;
}

// Install one host function on `target`, or as a global when it is null.
fn int install_function(Runtime* rt, HObject* target, char[] name, void* cfn, void* udata,
                        int arity, uint flags, bool simple) {
    TVal fv;
    int rc = embed::make_c_function(rt, name, cfn, udata, arity, (flags & BK_CTOR) != 0, &fv, simple);
    if (rc != BK_OK) return rc;
    if (target == null) return embed::declare_global(rt, name, fv);
    HString* k = rt.heap.str_intern(name);
    if (k == null) return fail(rt, BK_ERR_NOMEM, "out of memory");
    if (!target.put_prop(k, fv, hobject::PROP_FLAGS_WC, rt.heap)) {
        return fail(rt, BK_ERR_INTERNAL, "could not install function on target");
    }
    return BK_OK;
}

fn int bk_register_fn(void* ctxp, ulong target_id, char* name, void* fn_ptr, int arity, uint flags, void* udata)
        @export("bk_register_fn") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || name == null || fn_ptr == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal ov;
    HObject* target = null;
    if (target_id != 0) {
        target = as_object(ctxp, target_id, &ov);
        if (target == null) return rt.errcode;
    }
    return install_function(rt, target, ((ZString)name).str_view(), fn_ptr, udata, arity, flags, true);
}

fn uint bk_argc(void* ctxp) @export("bk_argc") {
    void* bctx = bctx_of(ctxp);
    return bctx == null ? 0 : builtins::host_argc((builtins::BuiltinContext*)bctx);
}

fn ulong bk_arg(void* ctxp, uint i) @export("bk_arg") {
    if (bctx_of(ctxp) == null) return 0;
    // Any index past argc reads as undefined; clamp so it stays in the index field.
    ulong index = min((ulong)heap::HOST_SCOPE_ARG0 + i, embed::SCOPE_INDEX_MASK);
    return embed::scope_handle(rt_of(ctxp), index);
}

fn ulong bk_this(void* ctxp) @export("bk_this") {
    if (bctx_of(ctxp) == null) return 0;
    return embed::scope_handle(rt_of(ctxp), (ulong)heap::HOST_SCOPE_THIS);
}

fn int bk_return(void* ctxp, ulong id) @export("bk_return") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return BK_ERR_INVALID;
    if (bctx_of(ctxp) == null) return fail(rt, BK_ERR_INVALID, "bk_return outside a host function");
    TVal value;
    if (!resolve(ctxp, id, &value)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    ulong held = store(rt, value);
    if (held == 0) return BK_ERR_FULL;
    Ctx* ctx = (Ctx*)ctxp;
    embed::slot_release(rt, ctx.host_return);
    ctx.host_return = held;
    return BK_OK;
}

fn int bk_set_global_property(void* ctxp, char* name, usz name_len, ulong val_id)
        @export("bk_set_global_property") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null || name == null) return BK_ERR_INVALID;
    embed::clear_err(rt);
    TVal v;
    if (!resolve(ctxp, val_id, &v)) return fail(rt, BK_ERR_INVALID, "invalid or freed value handle");
    return embed::declare_global(rt, name[:name_len], v);
}

fn ulong bk_get_new_target(void* ctxp) @export("bk_get_new_target") {
    if (bctx_of(ctxp) == null) return 0;
    return embed::scope_handle(rt_of(ctxp), (ulong)heap::HOST_SCOPE_NEW_TARGET);
}

fn int bk_is_constructor_call(void* ctxp) @export("bk_is_constructor_call") {
    void* bctx = bctx_of(ctxp);
    if (bctx == null) return 0;
    return builtins::host_is_construct((builtins::BuiltinContext*)bctx) ? 1 : 0;
}



// Set a pending exception without unwinding through C.
fn ulong bk_throw_error(void* ctxp, int kind, char* msg) @export("bk_throw_error") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    builtins::BuiltinContext call = { .heap = rt.heap, .vm = rt.vm };
    builtins::host_throw_error(&call, kind, msg == null ? (char[])"" : ((ZString)msg).str_view());
    embed::describe_error(rt, &call.throw_value);
    return 0;
}

fn ulong bk_throw(void* ctxp, ulong id) @export("bk_throw") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    TVal value;
    if (!resolve(ctxp, id, &value)) return bad_handle(rt);
    embed::describe_error(rt, &value);
    return 0;
}

fn ulong bk_new_c_function(void* ctxp, void* callback, char* name, int arity, uint flags, void* opaque) @export("bk_new_c_function") {
    Runtime* rt = rt_of(ctxp);
    if (rt == null) return 0;
    if (callback == null) { fail(rt, BK_ERR_INVALID, "null C function"); return 0; }
    TVal function;
    char[] fname = name == null ? (char[])"" : ((ZString)name).str_view();
    if (embed::make_c_function(rt, fname, callback, opaque, arity, (flags & BK_CTOR) != 0, &function) != BK_OK) return 0;
    return store(rt, function);
}

// ============================================================================
// Interrupt
// ============================================================================

// Install, replace, or clear the interrupt handler. The callback runs on the
// engine thread at VM safepoints; it must not call back into the engine. A
// host interrupting from another thread sets a flag in `opaque` and returns it
// here.
fn void bk_set_interrupt(void* rtp, void* cb, void* opaque) @export("bk_set_interrupt") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return;
    rt.heap.capi_interrupt_fn = cb;
    rt.heap.capi_interrupt_opaque = opaque;
    rt.heap.interrupt_budget = heap::INTERRUPT_BUDGET_INIT;
}

// Set the resident-memory budget in bytes; 0 disables it. The heap checks it
// after each GC cycle and calls the fatal handler when it is exceeded.
fn void bk_set_memory_limit(void* rtp, ulong bytes) @export("bk_set_memory_limit") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return;
    rt.heap.mem_limit = bytes;
}

fn void bk_request_interrupt(void* rtp) @export("bk_request_interrupt") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return;
    mem::@atomic_store(rt.heap.interrupt_requested, 1u);
    // A thread blocked in Atomics.wait sleeps on a condition, not on this flag.
    agent::wake_interrupt(rt.heap);
}

fn void bk_clear_interrupt(void* rtp) @export("bk_clear_interrupt") {
    Runtime* rt = (Runtime*)rtp;
    if (rt != null) mem::@atomic_store(rt.heap.interrupt_requested, 0u);
}

alias BkPromiseRejectionFn = fn void(void* ctx, ulong promise_id, ulong promise, ulong reason, int handled, void* opaque);

fn void capi_rejection_tracker(void* heap_raw, TVal promise, TVal reason, bool handled, void* udata) {
    Runtime* rt = (Runtime*)udata;
    ulong p = embed::slot_alloc(rt, promise);
    if (p == 0) return;
    defer embed::slot_release(rt, p);
    ulong r = embed::slot_alloc(rt, reason);
    if (r == 0) return;
    defer embed::slot_release(rt, r);
    BkPromiseRejectionFn cb = (BkPromiseRejectionFn)rt.promise_rejection_fn;
    cb(rt.active, (ulong)promise.get_heapptr(), p, r, handled ? 1 : 0, rt.promise_rejection_udata);
}

fn void bk_set_promise_rejection_tracker(void* rtp, void* cb, void* opaque)
        @export("bk_set_promise_rejection_tracker") {
    Runtime* rt = (Runtime*)rtp;
    if (rt == null) return;
    rt.promise_rejection_fn = cb;
    rt.promise_rejection_udata = opaque;
    rt.heap.promise_rejection_fn = cb != null ? &capi_rejection_tracker : null;
    rt.heap.promise_rejection_udata = rt;
}
