module duktape::capi;

import duktape::builtins;
import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::hobject;
import duktape::hstring;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;

// ============================================================================
// Status codes (must mirror include/jse.h)
// ============================================================================

const int JSE_OK            = 0;
const int JSE_ERR_NOMEM     = -1;
const int JSE_ERR_SYNTAX    = -2;
const int JSE_ERR_THROW     = -3;
const int JSE_ERR_INTERNAL  = -4;
const int JSE_ERR_INVALID   = -5;
const int JSE_ERR_TYPE      = -6;
const int JSE_ERR_FULL      = -7;

const int JSE_TYPE_UNDEFINED = 0;
const int JSE_TYPE_NULL      = 1;
const int JSE_TYPE_BOOLEAN   = 2;
const int JSE_TYPE_NUMBER    = 3;
const int JSE_TYPE_STRING    = 4;
const int JSE_TYPE_OBJECT    = 5;
const int JSE_TYPE_FUNCTION  = 6;
const int JSE_TYPE_OTHER     = 7;

const uint MAX_SLOTS = 1024;
const usz ERRBUF = 512;

// ============================================================================
// Runtime
// ============================================================================

// The engine keeps process-global state (compiler error buffer, hobject active
// heap), so exactly one runtime may exist at a time. Enforced, not documented.
struct Runtime {
    Heap*    heap;
    Vm*      vm;
    HObject* slots;          // GC root: anchors every host-held value
    uint     next_slot;
    uint     live;
    char[ERRBUF] errmsg;
    int      errcode;
    /// Innermost host-call context, or null outside a host callback. Lets the
    /// readers resolve a scope handle without the host threading the context
    /// through every call.
    void*    active_ctx;
}

Runtime* g_rt = null;

// Set once the engine's compile-time-populated tables are known good; see
// ensure_engine_init. Never cleared, since the tables outlive any runtime.
bool g_engine_ready = false;

fn void set_err(Runtime* rt, int code, char[] msg) {
    rt.errcode = code;
    usz n = msg.len < ERRBUF - 1 ? msg.len : ERRBUF - 1;
    for (usz i = 0; i < n; i++) rt.errmsg[i] = msg[i];
    rt.errmsg[n] = 0;
}

fn void clear_err(Runtime* rt) {
    rt.errcode = JSE_OK;
    rt.errmsg[0] = 0;
}

// The engine's one @init function (builtins::init_builtin_dispatch_table)
// normally runs from the C3 runtime's startup walk of the Mach-O/ELF init
// sections. That walk is only reliable when c3c also drives the final link:
// when this archive is linked by a foreign toolchain the C3 startup can bind
// to the wrong image header and either fault or silently skip the section, so
// the dispatch table stays all-null and the first builtin call misbehaves.
// Observed concretely with the Zig linker, which emits a second, bogus
// __mh_execute_header in __DATA,__bss that the walk latches onto.
//
// Running the initializer explicitly here removes the ABI's dependence on that
// walk entirely. It is idempotent -- it just re-stores compile-time constants
// into a fixed-size table -- so double execution with the startup path is
// harmless, and this is the only place a host can reach the engine first.
fn void ensure_engine_init() {
    if (g_engine_ready) return;
    g_engine_ready = true;
    builtins::init_builtin_dispatch_table();
}

fn int jse_open(void** out_rt) @export("jse_open") {
    if (out_rt == null) return JSE_ERR_INVALID;
    *out_rt = null;
    if (g_rt != null) return JSE_ERR_INVALID;   // single-runtime rule
    ensure_engine_init();

    Heap*? hpr = heap::create(null, null, null, null, null);
    if (catch hpr) return JSE_ERR_NOMEM;
    Heap* hp = hpr;

    Vm*? vr = vm::vm_create(hp);
    if (catch vr) { hp.destroy(); return JSE_ERR_NOMEM; }
    Vm* v = vr;

    // Slot registry: a plain object registered ONCE as a GC root. Values live
    // as ordinary properties, so put_prop/delete_prop do the increfs and the
    // mark phase reaches them transitively. Costs 1 of the 64 root entries.
    HObject*? sr = hp.alloc_object(hobject::ObjClass.OBJECT);
    if (catch sr) { vm::vm_destroy(v); hp.destroy(); return JSE_ERR_NOMEM; }
    HObject* slots = sr;
    hp.register_gc_root((types::HeapHeader*)slots);

    void* raw = hp.alloc_func(hp.heap_udata, Runtime::size);
    if (raw == null) { vm::vm_destroy(v); hp.destroy(); return JSE_ERR_NOMEM; }
    Runtime* rt = (Runtime*)raw;
    rt.heap = hp; rt.vm = v; rt.slots = slots;
    rt.next_slot = 1; rt.live = 0;
    rt.active_ctx = null;
    clear_err(rt);

    g_rt = rt;
    *out_rt = (void*)rt;
    return JSE_OK;
}

fn void jse_close(void* rtp) @export("jse_close") {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    Heap* hp = rt.heap;
    // Teardown order is load-bearing: vm_destroy uses heap.free_func.
    vm::vm_destroy(rt.vm);
    hp.free_func(hp.heap_udata, (void*)rt);
    hp.destroy();
    if (g_rt == rt) g_rt = null;
}

// ============================================================================
// Slot registry
// ============================================================================

fn uint slot_alloc(Runtime* rt, TVal v) {
    if (rt.live >= MAX_SLOTS) return 0;
    uint id = rt.next_slot;
    rt.next_slot++;
    if (rt.next_slot == 0) rt.next_slot = 1;
    HString* key = rt.heap.int_to_hstring((long)id);
    if (key == null) return 0;
    if (!rt.slots.put_prop(key, v, hobject::PROP_FLAGS_WEC)) return 0;
    rt.live++;
    return id;
}

/// Resolve any handle: a scope handle against the innermost host call, a
/// global slot id against the registry. Readers go through this so a host can
/// pass jse_arg() straight into jse_get_number and friends.
fn bool any_get(Runtime* rt, uint id, TVal* out) {
    if ((id & SCOPE_HANDLE_BIT) != 0) {
        if (rt == null || rt.active_ctx == null) return false;
        return resolve_handle(rt, rt.active_ctx, id, out);
    }
    if (rt == null) return false;
    return slot_get(rt, id, out);
}

fn bool slot_get(Runtime* rt, uint id, TVal* out) {
    if (id == 0) return false;
    HString* key = rt.heap.int_to_hstring((long)id);
    if (key == null) return false;
    TVal? tv = rt.slots.get_prop(key);
    if (catch tv) return false;
    *out = tv;
    return true;
}

fn void jse_value_free(void* rtp, uint id) @export("jse_value_free") {
    if (rtp == null || id == 0) return;
    Runtime* rt = (Runtime*)rtp;
    HString* key = rt.heap.int_to_hstring((long)id);
    if (key == null) return;
    if (rt.slots.delete_prop(key)) { if (rt.live > 0) rt.live--; }
}

// ============================================================================
// Eval
// ============================================================================

fn int jse_eval(void* rtp, char* src, usz len, uint* out_val) @export("jse_eval") {
    if (rtp == null || src == null) return JSE_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    clear_err(rt);
    if (out_val != null) *out_val = 0;

    Lexer lex = lexer::lexer_init(src[:len], rt.heap);
    lex.skip_hashbang();
    // compile_eval, not compile: a top-level *script* only yields a value via an
    // explicit RET, so `40+2` would come back undefined. eval-form code carries a
    // completion value, which is what an embedder expects from jse_eval.
    CompiledFunction*? fr = compiler::compile_eval(&lex, rt.heap);
    if (catch fr) {
        // Copy immediately: the compiler error buffer is process-global and
        // is clobbered by the next failing compile.
        char* m = compiler::last_error_msg();
        usz n = 0;
        while (m[n] != 0 && n < ERRBUF - 1) n++;
        // Some compiler failure paths return without populating the global
        // buffer (e.g. "var = = ="). Never hand the host an empty message.
        if (n == 0) {
            set_err(rt, JSE_ERR_SYNTAX, "SyntaxError");
        } else {
            set_err(rt, JSE_ERR_SYNTAX, m[:n]);
        }
        lex.free_arena();
        return JSE_ERR_SYNTAX;
    }
    CompiledFunction* f = fr;

    rt.heap.has_error = false;
    TVal? res = rt.vm.execute(f);
    lex.free_arena();

    if (catch res) {
        if (rt.heap.has_error) {
            describe_error(rt, &rt.heap.error_value);
            return JSE_ERR_THROW;
        }
        set_err(rt, JSE_ERR_INTERNAL, "internal VM error");
        return JSE_ERR_INTERNAL;
    }

    if (out_val != null) {
        TVal v = res;
        // As in jse_call: a failed slot_alloc must surface even for a
        // primitive, since handle 0 reads back as undefined and would
        // otherwise look like a successful result.
        uint id = slot_alloc(rt, v);
        if (id == 0 && !v.is_undefined()) {
            set_err(rt, JSE_ERR_FULL, "value slot table full");
            return JSE_ERR_FULL;
        }
        *out_val = id;
    }
    return JSE_OK;
}

/// Read property `key` off `o` or its prototype chain, returning it only if it
/// holds a string. Needed for the `name`/`message` pair on a thrown Error: an
/// engine-thrown TypeError owns only `message`, and `name` lives on
/// Error.prototype.
///
/// This walks the chain by hand instead of calling get_prop_proto because that
/// routes a Proxy anywhere on the chain back through the trap machinery and
/// into the VM. describe_error runs on the unwind path, where re-entering the
/// VM could throw again; a proxy link simply ends the search instead.
fn HString* str_prop(HObject* o, HString* key) {
    HObject* cur = o;
    uint depth = 0;
    while (cur != null && depth < 64) {
        if (cur.flags.exotic_proxyobj) return null;
        int idx = cur.find_prop_idx((void*)key);
        if (idx >= 0) {
            // An accessor slot holds a getter/setter pair, not a value. Reading
            // it would mean calling into the VM, so treat it as absent.
            if (cur.get_prop_flags((uint)idx).is_accessor) return null;
            TVal got = cur.prop_values()[idx];
            if (got.is_string()) return (HString*)got.get_heapptr();
            return null;
        }
        cur = cur.prototype;
        depth++;
    }
    return null;
}

/// Format a thrown value into the runtime error buffer without re-entering
/// the VM (a user toString could throw again on the unwind path). Every JS
/// value reaches a useful message: `throw 42` reports "42", not a placeholder.
fn void describe_error(Runtime* rt, TVal* ev) {
    if (ev.is_string()) {
        HString* s = (HString*)ev.get_heapptr();
        set_err(rt, JSE_ERR_THROW, s.get_data());
        return;
    }
    if (ev.is_undefined()) { set_err(rt, JSE_ERR_THROW, "undefined"); return; }
    if (ev.is_null())      { set_err(rt, JSE_ERR_THROW, "null"); return; }
    if (ev.is_boolean())   {
        set_err(rt, JSE_ERR_THROW, ev.get_boolean() ? "true" : "false");
        return;
    }
    if (ev.is_numeric()) {
        // Same shortest-roundtrip formatter the engine uses for Number->String,
        // and it is a pure buffer write: no VM re-entry, no allocation.
        char[64] nbuf;
        usz n = builtins::json_number_to_string(ev.get_number_or_fastint(), &nbuf[0], 64);
        set_err(rt, JSE_ERR_THROW, nbuf[:n]);
        return;
    }
    if (ev.is_object()) {
        HObject* o = (HObject*)ev.get_heapptr();
        HString* msg  = str_prop(o, rt.heap.strs[heap::BuiltinStr.MESSAGE]);
        HString* name = str_prop(o, rt.heap.strs[heap::BuiltinStr.NAME]);

        // "TypeError: x is not a function" -- name comes off the prototype, so
        // this reads like the message a JS host would print.
        if (name != null && msg != null && msg.blen != 0) {
            char[ERRBUF] buf;
            usz pos = 0;
            char[] np = name.get_data();
            char[] mp = msg.get_data();
            for (usz i = 0; i < np.len && pos < ERRBUF - 3; i++) buf[pos++] = np[i];
            buf[pos++] = ':';
            buf[pos++] = ' ';
            for (usz i = 0; i < mp.len && pos < ERRBUF - 1; i++) buf[pos++] = mp[i];
            set_err(rt, JSE_ERR_THROW, buf[:pos]);
            return;
        }
        if (msg != null && msg.blen != 0) { set_err(rt, JSE_ERR_THROW, msg.get_data()); return; }
        if (name != null && name.blen != 0) { set_err(rt, JSE_ERR_THROW, name.get_data()); return; }
        set_err(rt, JSE_ERR_THROW, "uncaught exception (object)");
        return;
    }
    set_err(rt, JSE_ERR_THROW, "uncaught exception");
}

// ============================================================================
// Readers
// ============================================================================

fn int jse_type_of(void* rtp, uint id) @export("jse_type_of") {
    if (rtp == null) return JSE_TYPE_OTHER;
    Runtime* rt = (Runtime*)rtp;
    TVal v;
    if (!any_get(rt, id, &v)) return JSE_TYPE_UNDEFINED;
    if (v.is_undefined()) return JSE_TYPE_UNDEFINED;
    if (v.is_null()) return JSE_TYPE_NULL;
    if (v.is_boolean()) return JSE_TYPE_BOOLEAN;
    if (v.is_numeric()) return JSE_TYPE_NUMBER;
    // A Symbol is a STRING-tagged HString with is_symbol set, so is_string()
    // alone would misreport it as a string and let jse_get_string hand back
    // the symbol's raw internal bytes.
    if (v.is_string()) {
        HString* s = (HString*)v.get_heapptr();
        if (s != null && s.is_symbol()) return JSE_TYPE_OTHER;
        return JSE_TYPE_STRING;
    }
    if (v.is_object()) {
        HObject* o = (HObject*)v.get_heapptr();
        if (o != null && o.flags.callable) return JSE_TYPE_FUNCTION;
        return JSE_TYPE_OBJECT;
    }
    return JSE_TYPE_OTHER;
}

// A reader that fails must leave a message behind: jse_last_error is documented
// as describing "the most recent failure", and a host that logs it on a bad
// status would otherwise print an empty string (or, worse, a stale message from
// an unrelated earlier call).
fn int reader_fail(Runtime* rt, int code, String msg) {
    set_err(rt, code, msg);
    return code;
}

fn int jse_get_number(void* rtp_in, uint id, double* out) @export("jse_get_number") {
    if (out == null) return JSE_ERR_INVALID;
    Runtime* rt = rtp_in != null ? (Runtime*)rtp_in : g_rt;
    if (rt == null) return JSE_ERR_INVALID;
    clear_err(rt);
    TVal v;
    if (!any_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_numeric()) return reader_fail(rt, JSE_ERR_TYPE, "value is not a number");
    *out = v.get_number_or_fastint();
    return JSE_OK;
}

fn int jse_get_bool(void* rtp_in, uint id, int* out) @export("jse_get_bool") {
    if (out == null) return JSE_ERR_INVALID;
    Runtime* rt = rtp_in != null ? (Runtime*)rtp_in : g_rt;
    if (rt == null) return JSE_ERR_INVALID;
    clear_err(rt);
    TVal v;
    if (!any_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_boolean()) return reader_fail(rt, JSE_ERR_TYPE, "value is not a boolean");
    *out = v.get_boolean() ? 1 : 0;
    return JSE_OK;
}

// UTF-8 conversion sink. write_cesu8_as_utf8's callback takes no udata, so a
// module-global sink is the only option; single-runtime + no threads make it safe.
char* g_sink;
usz   g_sink_len;
usz   g_sink_cap;

fn void sink_put(char c) {
    if (g_sink_len + 1 < g_sink_cap) { g_sink[g_sink_len] = c; }
    g_sink_len++;
}

/// Copy a JS string out as NUL-terminated UTF-8. Two-call protocol: pass
/// buf==null to learn the required size (excluding NUL).
fn int jse_get_string(void* rtp_in, uint id, char* buf, usz cap, usz* out_len) @export("jse_get_string") {
    Runtime* rt = rtp_in != null ? (Runtime*)rtp_in : g_rt;
    if (rt == null) return JSE_ERR_INVALID;
    clear_err(rt);
    TVal v;
    if (!any_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_string()) return reader_fail(rt, JSE_ERR_TYPE, "value is not a string");
    HString* s = (HString*)v.get_heapptr();
    // Symbols share the string tag but carry no meaningful text; copying their
    // bytes out would yield invalid UTF-8. JS forbids implicit conversion too.
    if (s != null && s.is_symbol()) return JSE_ERR_TYPE;

    g_sink = buf; g_sink_len = 0; g_sink_cap = (buf == null) ? 0 : cap;
    hstring::write_cesu8_as_utf8(s.get_data(), &sink_put);
    usz need = g_sink_len;
    if (out_len != null) *out_len = need;
    if (buf == null) return JSE_OK;
    if (need + 1 > cap) return reader_fail(rt, JSE_ERR_FULL, "buffer too small for string");
    buf[need] = 0;
    return JSE_OK;
}

// ============================================================================
// Errors / microtasks
// ============================================================================

fn char* jse_last_error(void* rtp) @export("jse_last_error") {
    if (rtp == null) return null;
    Runtime* rt = (Runtime*)rtp;
    return &rt.errmsg[0];
}

fn int jse_last_error_code(void* rtp) @export("jse_last_error_code") {
    if (rtp == null) return JSE_ERR_INVALID;
    return ((Runtime*)rtp).errcode;
}

fn void jse_drain_microtasks(void* rtp) @export("jse_drain_microtasks") {
    if (rtp == null) return;
    Runtime* rt = (Runtime*)rtp;
    rt.heap.drain_microtasks((void*)rt.vm);
}

fn char* jse_version() @export("jse_version") {
    return "0.1.0";
}

// ============================================================================
// Host functions
//
// A host callback is a C function the engine calls when JS invokes the
// corresponding function value. The engine side (builtins::dispatch_host)
// stages a per-call scope; everything here is the opaque-handle layer over it.
//
// Handles inside a callback are SCOPE handles: they carry the high bit and are
// valid only for the duration of that call. jse_value_persist copies one into
// the global slot registry when the host needs it to outlive the callback.
// ============================================================================

const uint SCOPE_HANDLE_BIT = 0x8000_0000;

/// The C-facing callback signature: (ctx, udata).
alias JseHostFn = fn void(void*, void*);

/// Encode a scope handle for argument/this/new_target index `idx`.
///
/// Scope handles are distinguished from global slot ids by the high bit, so
/// jse_type_of and the readers accept both kinds without separate entry points.
fn uint scope_handle(uint idx) @inline {
    return SCOPE_HANDLE_BIT | idx;
}

/// Resolve any handle to a TVal. Global slot ids go to the slot registry;
/// scope handles read the innermost host call scope through the context.
fn bool resolve_handle(Runtime* rt, void* ctxp, uint id, TVal* out) {
    if ((id & SCOPE_HANDLE_BIT) != 0) {
        if (ctxp == null) return false;
        builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
        uint idx = id & ~SCOPE_HANDLE_BIT;
        if (idx == heap::HOST_SCOPE_THIS)       { *out = builtins::host_this(ctx); return true; }
        if (idx == heap::HOST_SCOPE_NEW_TARGET) { *out = builtins::host_new_target(ctx); return true; }
        *out = builtins::host_arg(ctx, idx - heap::HOST_SCOPE_ARG0);
        return true;
    }
    return slot_get(rt, id, out);
}

/// Trampoline: every registered host function enters the engine through this
/// one C3 function, which forwards to the C callback with the context as an
/// opaque pointer. The udata the engine stored is a HostReg* holding the real
/// C function pointer and the host's own udata.
struct HostReg {
    void* cfn;
    void* udata;
}

fn void host_trampoline(builtins::BuiltinContext* ctx, void* udata) {
    if (udata == null) return;
    HostReg* reg = (HostReg*)udata;
    if (reg.cfn == null) return;
    JseHostFn cfn = (JseHostFn)reg.cfn;
    // Publish this call's context so the readers can resolve scope handles
    // without the host threading it through. Saved and restored rather than
    // cleared: a host -> JS -> host chain must leave the outer call's context
    // in place when the inner one returns.
    void* prev = null;
    if (g_rt != null) { prev = g_rt.active_ctx; g_rt.active_ctx = (void*)ctx; }
    cfn((void*)ctx, reg.udata);
    if (g_rt != null) { g_rt.active_ctx = prev; }
}

/// Register `cfn` as a global function named `name`.
///
/// Returns JSE_OK, or JSE_ERR_INVALID / JSE_ERR_NOMEM. The binding is created
/// on the global environment, so JS reaches it by bare name.
fn int jse_register_fn(void* rtp, char* name, usz name_len, void* cfn, void* udata,
                       int arity, int constructable) @export("jse_register_fn") {
    if (rtp == null || name == null || cfn == null) return JSE_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    clear_err(rt);

    HString* nm = rt.heap.str_intern(name[:name_len]);
    if (nm == null) { set_err(rt, JSE_ERR_NOMEM, "could not intern function name"); return JSE_ERR_NOMEM; }

    // The registration record outlives the call, so it is heap-allocated and
    // owned by the runtime; the host function table keeps the only pointer.
    void* raw = rt.heap.alloc_func(rt.heap.heap_udata, HostReg::size);
    if (raw == null) { set_err(rt, JSE_ERR_NOMEM, "out of memory"); return JSE_ERR_NOMEM; }
    HostReg* reg = (HostReg*)raw;
    reg.cfn = cfn;
    reg.udata = udata;

    long slot = rt.heap.register_host_fn((void*)&host_trampoline, (void*)reg, (void*)nm,
                                         arity, constructable != 0);
    if (slot < 0) {
        rt.heap.free_func(rt.heap.heap_udata, raw);
        set_err(rt, JSE_ERR_NOMEM, "host function table full");
        return JSE_ERR_NOMEM;
    }

    HObject*? fo = builtins::make_host_function(rt.heap, (uint)slot);
    if (catch fo) { set_err(rt, JSE_ERR_NOMEM, "could not create function object"); return JSE_ERR_NOMEM; }
    TVal fv;
    fv.set_object(fo);
    if (!env::env_declare(rt.vm.global_env, (void*)nm, fv)) {
        set_err(rt, JSE_ERR_INTERNAL, "could not bind function name");
        return JSE_ERR_INTERNAL;
    }
    return JSE_OK;
}

// --- inside a callback ------------------------------------------------------

fn uint jse_argc(void* ctxp) @export("jse_argc") {
    if (ctxp == null) return 0;
    return builtins::host_argc((builtins::BuiltinContext*)ctxp);
}

/// Handle to argument `i`. Out-of-range yields a handle to undefined, matching
/// JS semantics and sparing every host an arity check.
fn uint jse_arg(void* ctxp, uint i) @export("jse_arg") {
    return scope_handle(heap::HOST_SCOPE_ARG0 + i);
}

fn uint jse_this(void* ctxp) @export("jse_this") {
    return scope_handle(heap::HOST_SCOPE_THIS);
}

fn uint jse_new_target(void* ctxp) @export("jse_new_target") {
    return scope_handle(heap::HOST_SCOPE_NEW_TARGET);
}

fn int jse_is_construct(void* ctxp) @export("jse_is_construct") {
    if (ctxp == null) return 0;
    return builtins::host_is_construct((builtins::BuiltinContext*)ctxp) ? 1 : 0;
}

/// Set the callback's return value from a handle.
fn void jse_return(void* ctxp, uint id) @export("jse_return") {
    if (ctxp == null || g_rt == null) return;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    TVal v;
    if (!resolve_handle(g_rt, ctxp, id, &v)) return;
    builtins::host_return(ctx, v);
}

fn void jse_return_number(void* ctxp, double d) @export("jse_return_number") {
    if (ctxp == null) return;
    TVal v;
    v.set_number(d);
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

fn void jse_return_bool(void* ctxp, int b) @export("jse_return_bool") {
    if (ctxp == null) return;
    TVal v;
    v.set_boolean(b != 0);
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

fn void jse_return_null(void* ctxp) @export("jse_return_null") {
    if (ctxp == null) return;
    TVal v;
    v.set_null();
    builtins::host_return((builtins::BuiltinContext*)ctxp, v);
}

/// Set the return value to a fresh JS string built from UTF-8 bytes.
fn void jse_return_string(void* ctxp, char* utf8, usz len) @export("jse_return_string") {
    if (ctxp == null || utf8 == null) return;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    builtins::host_return(ctx, builtins::host_new_string(ctx, utf8[:len]));
}

/// Throw a fresh Error of `kind` with `msg`. Does not unwind: the callback
/// must still return normally, and the throw beats any return value set.
fn void jse_throw_error(void* ctxp, int kind, char* msg) @export("jse_throw_error") {
    if (ctxp == null || msg == null) return;
    usz n = 0;
    while (msg[n] != 0) n++;
    builtins::host_throw_error((builtins::BuiltinContext*)ctxp, kind, msg[:n]);
}

/// Throw an arbitrary value by handle.
fn void jse_throw(void* ctxp, uint id) @export("jse_throw") {
    if (ctxp == null || g_rt == null) return;
    TVal v;
    if (!resolve_handle(g_rt, ctxp, id, &v)) return;
    builtins::host_throw((builtins::BuiltinContext*)ctxp, v);
}

/// Promote a scope handle to a runtime-owned global handle the host may keep
/// past the callback. The caller then owns it and must jse_value_free it.
fn uint jse_value_persist(void* ctxp, uint id) @export("jse_value_persist") {
    if (g_rt == null) return 0;
    TVal v;
    if (!resolve_handle(g_rt, ctxp, id, &v)) return 0;
    return slot_alloc(g_rt, v);
}

/// Call a JS function from host code.
///
/// `argv` is an array of `argc` handles. On success stores a scope-independent
/// global handle in *out_val (caller owns it) and returns JSE_OK. On an
/// exception in the callee the throw is staged on the context, so the host
/// should return promptly; the status is JSE_ERR_THROW.
fn int jse_call(void* ctxp, uint func_id, uint* argv, uint argc, uint this_id,
                uint* out_val) @export("jse_call") {
    if (ctxp == null || g_rt == null) return JSE_ERR_INVALID;
    builtins::BuiltinContext* ctx = (builtins::BuiltinContext*)ctxp;
    Runtime* rt = g_rt;
    if (out_val != null) *out_val = 0;

    TVal fv;
    if (!resolve_handle(rt, ctxp, func_id, &fv)) return JSE_ERR_INVALID;
    TVal tv;
    if (this_id == 0) { tv.set_undefined(); } else if (!resolve_handle(rt, ctxp, this_id, &tv)) { tv.set_undefined(); }

    // Bounded stack array: the engine's own call paths cap staged arguments
    // the same way, and a host needing more can build an array in JS.
    TVal[16] args;
    uint n = argc > 16 ? 16 : argc;
    for (uint i = 0; i < n; i++) {
        TVal a;
        if (argv == null || !resolve_handle(rt, ctxp, argv[i], &a)) a.set_undefined();
        args[i] = a;
    }

    bool ok = false;
    TVal res = builtins::host_call(ctx, fv, &args[0], n, tv, &ok);
    if (!ok) return JSE_ERR_THROW;
    if (out_val != null) {
        // Report exhaustion for every value kind. Guarding on
        // is_heap_allocated would hand back handle 0 for an exhausted
        // primitive, and handle 0 reads as undefined -- a silent wrong
        // answer rather than an error.
        uint id = slot_alloc(rt, res);
        if (id == 0 && !res.is_undefined()) return JSE_ERR_FULL;
        *out_val = id;
    }
    return JSE_OK;
}
