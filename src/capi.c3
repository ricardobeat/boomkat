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
        uint id = slot_alloc(rt, v);
        if (id == 0 && v.is_heap_allocated()) {
            set_err(rt, JSE_ERR_FULL, "value slot table full");
            return JSE_ERR_FULL;
        }
        *out_val = id;
    }
    return JSE_OK;
}

/// Format a thrown value into the runtime error buffer without re-entering
/// the VM (a user toString could throw again on the unwind path).
fn void describe_error(Runtime* rt, TVal* ev) {
    if (ev.is_string()) {
        HString* s = (HString*)ev.get_heapptr();
        set_err(rt, JSE_ERR_THROW, s.get_data());
        return;
    }
    if (ev.is_object()) {
        HObject* o = (HObject*)ev.get_heapptr();
        HString* mk = rt.heap.strs[heap::BuiltinStr.MESSAGE];
        TVal? mv = o.get_prop(mk);
        if (try m = mv) {
            if (m.is_string()) {
                HString* s = (HString*)m.get_heapptr();
                set_err(rt, JSE_ERR_THROW, s.get_data());
                return;
            }
        }
        set_err(rt, JSE_ERR_THROW, "uncaught exception");
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
    if (!slot_get(rt, id, &v)) return JSE_TYPE_UNDEFINED;
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

fn int jse_get_number(void* rtp, uint id, double* out) @export("jse_get_number") {
    if (rtp == null || out == null) return JSE_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    clear_err(rt);
    TVal v;
    if (!slot_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
    if (!v.is_numeric()) return reader_fail(rt, JSE_ERR_TYPE, "value is not a number");
    *out = v.get_number_or_fastint();
    return JSE_OK;
}

fn int jse_get_bool(void* rtp, uint id, int* out) @export("jse_get_bool") {
    if (rtp == null || out == null) return JSE_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    clear_err(rt);
    TVal v;
    if (!slot_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
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
fn int jse_get_string(void* rtp, uint id, char* buf, usz cap, usz* out_len) @export("jse_get_string") {
    if (rtp == null) return JSE_ERR_INVALID;
    Runtime* rt = (Runtime*)rtp;
    clear_err(rt);
    TVal v;
    if (!slot_get(rt, id, &v)) return reader_fail(rt, JSE_ERR_INVALID, "invalid or freed value handle");
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
